RigidBodyDynamics.separation(obs::Obstacle, p::Point3D) = separation(obs.contact_face, p)
contact_normal(obs::Obstacle) = obs.contact_face.outward_normal

function τ_external_wrench(β,λ,c_n,body,contact_point,obstacle,D,world_frame,total_weight,
                           rel_transform,geo_jacobian)
    # compute force in contact frame (obstacle frame)
    n = contact_normal(obstacle)
    v = c_n .* n.v
    for i in eachindex(β)
        v += β[i] .* D[i].v
    end
    contact_force = FreeVector3D(n.frame, total_weight * v)

    # transform from obstacle to world frame   
    c = transform(contact_force, rel_transform[1])
    p = transform(contact_point, rel_transform[2])
    w = Wrench(p, c)

    # convert wrench in world frame to torque in joint coordinates
    torque(geo_jacobian, w)
end

function τ_total(x_sol::AbstractArray{T},β_selector,λ_selector,c_n_selector,num_v,num_contacts,β_dim,bodies,contact_points,obstacles,Ds,
                 world_frame,total_weight,rel_transforms,geo_jacobians) where T     
    β_sol = reshape(x_sol[β_selector],β_dim,num_contacts)
    λ_sol = x_sol[λ_selector]
    c_n_sol = x_sol[c_n_selector]
    
    τ_external_wrenches = zeros(T,num_v)
    for i = 1:num_contacts
        β = β_sol[:,i]
        λ = λ_sol[i]
        c_n = c_n_sol[i]
        τ_external_wrenches += τ_external_wrench(β,λ,c_n,
                                                 bodies[i],contact_points[i],obstacles[i],Ds[i],
                                                 world_frame,total_weight,
                                                 rel_transforms[i],geo_jacobians[i])
    end
    
    τ_external_wrenches
end

function complementarity_contact_constraints(x::AbstractArray{T},ϕs::AbstractArray{M},μs,Dtv,slack_selector,β_selector,λ_selector,c_n_selector,β_dim,num_contacts) where {T,M}
    # dist * c_n = 0
    comp_con = ϕs .* x[c_n_selector] .- x[slack_selector].^2
    
    # (λe + Dtv)' * β = 0
    λ_all = repmat(x[λ_selector]',β_dim,1)
    λpDtv = λ_all .+ Dtv
    β_all = reshape(x[β_selector],β_dim,num_contacts)    
    for i = 1:num_contacts
        comp_con = vcat(comp_con, λpDtv[:,i] .* β_all[:,i] .- x[slack_selector].^2)
    end
    
    # (μ * c_n - sum(β)) * λ = 0
    comp_con = vcat(comp_con, (μs .* x[c_n_selector] - sum(β_all,1)[:]) .* x[λ_selector] .- x[slack_selector].^2)
    
    comp_con
end

function dynamics_contact_constraints(x::AbstractArray{T},β_selector,λ_selector,c_n_selector,HΔv,Δt,u0,dyn_bias,num_v,num_contacts,β_dim,bodies,contact_points,obstacles,Ds,
                              world_frame,total_weight,rel_transforms,geo_jacobians) where T    
    # manipulator eq constraint
    bias = dyn_bias + τ_total(x,β_selector,λ_selector,c_n_selector,num_v,num_contacts,β_dim,bodies,contact_points,obstacles,Ds,
                              world_frame,total_weight,rel_transforms,geo_jacobians)
    
    dyn_con = HΔv .- Δt .* (u0 .- bias)
    
    dyn_con
end

function pos_contact_constraints(x::AbstractArray{T},num_contacts,β_dim,β_selector,λ_selector,c_n_selector,Dtv,μs) where T    
    # β >= 0
    pos_con = -x[β_selector]
    # λ >= 0 
    pos_con = vcat(pos_con, -x[λ_selector])
    # c_n >= 0
    pos_con = vcat(pos_con, -x[c_n_selector])
    
    # λe + D'*v >= 0
    λ_all = repmat(x[λ_selector]',β_dim,1)
    pos_con = vcat(pos_con, reshape(-(λ_all .+ Dtv),β_dim*num_contacts,1))
    
    # μ*c_n - sum(β) >= 0
    pos_con = vcat(pos_con, -(μs.*x[c_n_selector] - reshape(x[β_selector],β_dim,num_contacts)'*ones(β_dim)))

    pos_con
end

function solve_implicit_contact_τ(sim_data,ϕs,Dtv,HΔv,dyn_bias,
                                  q0::AbstractArray{M},v0::AbstractArray{M},u0::AbstractArray{M},
                                  qnext::AbstractArray{T},vnext::AbstractArray{T}) where {M, T}

    num_x_contact = 1+sim_data.num_contacts*(sim_data.β_dim+2)

    # x := [slack,β1,λ1,c_n1,β2,λ2,c_n2,...]    
    x0 = zeros(T,num_x_contact)

    f = x̃ -> begin
        comp_con = complementarity_contact_constraints(x̃,ϕs,sim_data.μs,Dtv,
                                                       sim_data.slack_selector,sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,
                                                       sim_data.β_dim,sim_data.num_contacts)
        comp_con'*comp_con + x̃[sim_data.slack_selector]'*x̃[sim_data.slack_selector]
    end
    h = x̃ -> dynamics_contact_constraints(x̃,sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,HΔv,sim_data.Δt,u0,dyn_bias,sim_data.num_v,sim_data.num_contacts,sim_data.β_dim,
                                          sim_data.bodies,sim_data.contact_points,sim_data.obstacles,sim_data.Ds,
                                          sim_data.world_frame,sim_data.total_weight,sim_data.rel_transforms,sim_data.geo_jacobians)
    g = x̃ -> pos_contact_constraints(x̃,sim_data.num_contacts,sim_data.β_dim,sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,Dtv,sim_data.μs)
    
    num_h = sim_data.num_v
    num_g = sim_data.num_contacts*(2*sim_data.β_dim+3)
    
    # parameters of the augmented lagrangian method
    N = 5
    α_vect = [1.^i for i in 1:N]
    c_vect = [2.^i for i in 1:N]
    I = eye(num_x_contact)
    
    x = auglag_solve(x0,f,h,g,num_h,num_g,α_vect,c_vect,I)

    # TODO update this to new constraints 
    # x = ip_solve(x0,f,h,g,num_h,num_g)
                   
    return τ_total(x,sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,sim_data.num_v,sim_data.num_contacts,sim_data.β_dim,sim_data.bodies,sim_data.contact_points,sim_data.obstacles,sim_data.Ds,
                   sim_data.world_frame,sim_data.total_weight,sim_data.rel_transforms,sim_data.geo_jacobians)
end