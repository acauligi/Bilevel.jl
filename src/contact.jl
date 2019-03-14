struct ContactParams
    ϕs
    Dtv
    rel_transforms
    geo_jacobians
    geo_jacobians_surfaces
    H
    HΔv
    bias
    contact_x0
    contact_λ0
    contact_μ0
end

function τ_external_wrench(β,λ,c_n,body,contact_point,obstacle,D,world_frame,total_weight,
                           rel_transform,geo_jacobian;geo_jacobian_surface=Nothing)
    # compute force in contact frame (obstacle frame)
    n = contact_normal(obstacle)
    v = c_n .* n.v
    for i in 1:length(β)
        v += β[i] .* Array(D[i].v)
    end

    contact_force = total_weight * v

    # convert contact force from surface frame to world frame
    c = (rel_transform[1].mat * vcat(contact_force,1.))[1:3]

    # convert contact point from body frame to world frame
    p = transform(contact_point, rel_transform[2])

    # wrench in world frame
    w_linear = c
    w_angular = p.v × c

    # convert wrench from world frame to torque in joint coordinates
    τ = geo_jacobian.linear' * w_linear + geo_jacobian.angular' * w_angular

    # surface reaction torque
    if !isa(geo_jacobian_surface,Nothing)
        surface_contact_force = -contact_force
        # world frame
        cs = (rel_transform[1].mat * vcat(surface_contact_force,1.))[1:3]
        # wrench
        ws_linear = cs
        ws_angular = p.v × cs
        τs = geo_jacobian_surface.linear' * ws_linear + geo_jacobian_surface.angular' * ws_angular

        τ += τs
    end

    τ
end

function τ_total(x_sol::AbstractArray{T},rel_transforms,geo_jacobians,geo_jacobians_surfaces,sim_data) where T
    β_selector = sim_data.β_selector
    λ_selector = sim_data.λ_selector
    c_n_selector = sim_data.c_n_selector
    num_v = sim_data.num_v
    num_contacts = sim_data.num_contacts
    β_dim = sim_data.β_dim
    bodies = sim_data.bodies
    contact_points = sim_data.contact_points
    obstacles = sim_data.obstacles
    Ds = sim_data.Ds
    world_frame = sim_data.world_frame
    total_weight = sim_data.total_weight

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
                                                 rel_transforms[i],geo_jacobians[i],
                                                 geo_jacobian_surface=geo_jacobians_surfaces[i])
    end

    τ_external_wrenches
end

function fischer_burm(a,b)
    a .+ b .- sqrt.(a.^2 .+ b.^2 .+ eps(1.))
end

function complementarity_contact_constraints(x,ϕs,Dtv,sim_data)
    μs = sim_data.μs
    β_selector = sim_data.β_selector
    λ_selector = sim_data.λ_selector
    c_n_selector = sim_data.c_n_selector
    β_dim = sim_data.β_dim
    num_contacts = sim_data.num_contacts

    # dist * c_n = 0
    α = 0.
    comp_con = (ϕs .- α) .* x[c_n_selector]

    # (λe + Dtv)' * β = 0
    λ_all = repeat(x[λ_selector]',β_dim,1)
    λpDtv = λ_all .+ Dtv
    β_all = reshape(x[β_selector],β_dim,num_contacts)
    for i = 1:num_contacts
        # comp_con = vcat(comp_con, λpDtv[:,i]' * β_all[:,i])
        comp_con = vcat(comp_con, fischer_burm(λpDtv[:,i],β_all[:,i]))
    end

    # (μ * c_n - sum(β)) * λ = 0
    # comp_con = vcat(comp_con, (μs .* x[c_n_selector] - sum(β_all,dims=1)[:]) .* x[λ_selector])
    comp_con = vcat(comp_con, fischer_burm((μs .* x[c_n_selector] - sum(β_all,dims=1)[:]),x[λ_selector]))

    comp_con
end

function complementarity_contact_constraints_relaxed(x,slack,ϕs,Dtv,sim_data)
    μs = sim_data.μs
    β_selector = sim_data.β_selector
    λ_selector = sim_data.λ_selector
    c_n_selector = sim_data.c_n_selector
    β_dim = sim_data.β_dim
    num_contacts = sim_data.num_contacts

    # dist * c_n = 0
    α = 0.
    comp_con = (ϕs .- α) .* x[c_n_selector] .- dot(slack,slack)

    # (λe + Dtv)' * β = 0
    λ_all = repeat(x[λ_selector]',β_dim,1)
    λpDtv = λ_all .+ Dtv
    β_all = reshape(x[β_selector],β_dim,num_contacts)
    for i = 1:num_contacts
        comp_con = vcat(comp_con, λpDtv[:,i] .* β_all[:,i] .- dot(slack,slack))
    end

    # (μ * c_n - sum(β)) * λ = 0
    comp_con = vcat(comp_con, (μs .* x[c_n_selector] - sum(β_all,dims=1)[:]) .* x[λ_selector] .- dot(slack,slack))

    comp_con
end

function dynamics_contact_constraints(x,rel_transforms,geo_jacobians,geo_jacobians_surfaces,HΔv,bias,sim_data)
    # manipulator eq constraint
    τ_contact = τ_total(x,rel_transforms,geo_jacobians,geo_jacobians_surfaces,sim_data)
    dyn_con = HΔv .-  sim_data.Δt .* (bias .- τ_contact)

    dyn_con
end

function pos_contact_constraints(x,Dtv,sim_data)
    β_selector = sim_data.β_selector
    λ_selector = sim_data.λ_selector
    c_n_selector = sim_data.c_n_selector
    num_contacts = sim_data.num_contacts
    β_dim = sim_data.β_dim
    μs = sim_data.μs

    # λe + D'*v >= 0
    λ_all = repeat(x[λ_selector]',β_dim,1)
    pos_con = reshape(-(λ_all .+ Dtv),β_dim*num_contacts,1)

    # μ*c_n - sum(β) >= 0
    β_all = reshape(x[β_selector],β_dim,num_contacts)
    pos_con = vcat(pos_con, -(μs.*x[c_n_selector] - sum(β_all,dims=1)[:]))

    pos_con = vcat(pos_con, 0. .- x, x .- 100.)

    pos_con
end

function solve_implicit_contact_τ_maxdiss(sim_data,ϕs,Dtv,rel_transforms,geo_jacobians,H,bias,v0)
    # just assume one contact point for now
    j = 1
    
    p = transform(sim_data.contact_points[j], rel_transforms[j][2])
    P = zeros(3,3)
    P[1,2] = -p.v[3]
    P[1,3] = p.v[2]
    P[2,1] = p.v[3]
    P[2,3] = -p.v[1]
    P[3,1] = -p.v[2]
    P[3,2] = p.v[1]
    D = hcat(map(d->d.v,sim_data.Ds[j])...)
    F = hcat(contact_normal(sim_data.obstacles[j]).v,D)
    J = sim_data.total_weight*F'*(geo_jacobians[j].linear + P'*geo_jacobians[j].angular)
    Hi = inv(H)
    
    Q = sim_data.Δt*J*Hi*J'
    q = -J*(sim_data.Δt*Hi*bias + v0)
    
    num_comp = sim_data.num_contacts*(2+sim_data.β_dim)
    num_pos = sim_data.num_contacts*(1+sim_data.β_dim) + 2*sim_data.num_contacts*(2+sim_data.β_dim)
    x0 = zeros(sim_data.num_contacts*(2+sim_data.β_dim)+1)
    λ0 = zeros(1)
    μ0 = zeros(num_pos+num_comp)
    
    f = x̃ -> begin
        slack = x̃[1]
        x = x̃[2:end]
        z = vcat(x[sim_data.c_n_selector],x[sim_data.β_selector])
        .5*z'*Q*z + q'*z + slack^2
    end
    h = x̃ -> begin
        x = x̃[2:end]
        # cn = x[sim_data.c_n_selector] - 1.
        # display(sim_data.Δt*J*Hi*J'*x)
        # p = -(J*v0 - sim_data.Δt*J*Hi*J'*x + sim_data.Δt*J*Hi*bias)
        # display(p)
        p = x[sim_data.c_n_selector]
        return p
    end
    g = x̃ -> begin
        slack = x̃[1]
        x = x̃[2:end]
        p = pos_contact_constraints(x,Dtv,sim_data)
        c = 1. * complementarity_contact_constraints_relaxed(x,slack,ϕs,Dtv,sim_data)
        return vcat(p,c)
    end

    # if ip_method
        # (x,λ,μ) = (ip_solve(x0,f,h,g,length(λ0),length(μ0)),λ0,μ0)
    # else
        (x,λ,μ) = auglag_solve(x0,λ0,μ0,f,h,g,in_place=false,num_fosteps=5,num_sosteps=10)
    # end

    return x[2:end], λ, μ
end

function solve_implicit_contact_τ(sim_data,ϕs,Dtv,rel_transforms,geo_jacobians,geo_jacobians_surfaces,HΔv,bias,x0,λ0,μ0;ip_method=false,in_place=true,comp_scale=1.,num_fosteps=1,num_sosteps=9)
    f = x̃ -> begin
        return sum(x̃[sim_data.β_selector]) + sum(x̃[sim_data.c_n_selector])
    end
    h = x̃ -> begin
        d = dynamics_contact_constraints(x̃,rel_transforms,geo_jacobians,geo_jacobians_surfaces,HΔv,bias,sim_data)
        c = comp_scale * complementarity_contact_constraints(x̃,ϕs,Dtv,sim_data)
        return vcat(d,c)
    end
    g = x̃ -> begin
        p = pos_contact_constraints(x̃,Dtv,sim_data)
        return p
    end

    if ip_method
        (x,λ,μ) = (ip_solve(x0,f,h,g,length(λ0),length(μ0)),λ0,μ0)
    else
        (x,λ,μ) = auglag_solve(x0,λ0,μ0,f,h,g,in_place=in_place,num_fosteps=num_fosteps,num_sosteps=num_sosteps)
    end

    return x, λ, μ
end

function compute_contact_params(sim_data,q0::AbstractArray{T},v0::AbstractArray{T},u0::AbstractArray{T},qnext::AbstractArray{M},vnext::AbstractArray{M}) where {T,M}
    x0 = MechanismState{T}(sim_data.mechanism)
    set_configuration!(x0,q0)
    set_velocity!(x0,v0)
    H = mass_matrix(x0)

    xnext = MechanismState{M}(sim_data.mechanism)
    set_configuration!(xnext, qnext)
    set_velocity!(xnext, vnext)

    num_dyn = sim_data.num_v
    num_comp = sim_data.num_contacts*(2+sim_data.β_dim)
    num_pos = sim_data.num_contacts*(1+sim_data.β_dim) + 2*sim_data.num_contacts*(2+sim_data.β_dim)

    # aug lag initial guesses
    contact_x0 = zeros(sim_data.num_contacts*(2+sim_data.β_dim))
    contact_λ0 = zeros(num_dyn+num_comp)
    # contact_λ0 = zeros(num_comp)
    contact_μ0 = zeros(num_pos)

    Dtv = Matrix{M}(undef,sim_data.β_dim,sim_data.num_contacts)
    rel_transforms = Vector{Tuple{Transform3D{M}, Transform3D{M}}}(undef, sim_data.num_contacts) # force transform, point transform
    geo_jacobians = Vector{GeometricJacobian{Matrix{M}}}(undef, sim_data.num_contacts)
    geo_jacobians_surfaces = Vector{Union{Nothing,GeometricJacobian{Matrix{M}}}}(undef, sim_data.num_contacts)
    ϕs = Vector{M}(undef, sim_data.num_contacts)
    for i = 1:sim_data.num_contacts
        v = point_velocity(twist_wrt_world(xnext,sim_data.bodies[i]), transform_to_root(xnext, sim_data.contact_points[i].frame) * sim_data.contact_points[i])
        Dtv[:,i] = map(sim_data.Ds[i]) do d
            dot(transform_to_root(xnext, d.frame) * d, v)
        end
        rel_transforms[i] = (relative_transform(xnext, sim_data.obstacles[i].contact_face.outward_normal.frame, sim_data.world_frame),
                                      relative_transform(xnext, sim_data.contact_points[i].frame, sim_data.world_frame))
        geo_jacobians[i] = geometric_jacobian(xnext, sim_data.paths[i])
        if !isa(sim_data.surface_paths[i],Nothing)
            geo_jacobians_surfaces[i] = geometric_jacobian(xnext, sim_data.surface_paths[i])
        else
            geo_jacobians_surfaces[i] = nothing
        end
        ϕs[i] = separation(sim_data.obstacles[i], transform(xnext, sim_data.contact_points[i], sim_data.obstacles[i].contact_face.outward_normal.frame))
    end

    config_derivative = configuration_derivative(xnext)
    HΔv = H * (vnext - v0)
    bias = u0 .- dynamics_bias(xnext)

    contact_params = ContactParams(ϕs,Dtv,rel_transforms,geo_jacobians,geo_jacobians_surfaces,H,HΔv,bias,contact_x0,contact_λ0,contact_μ0)

    return contact_params
end

function solve_implicit_contact_τ(sim_data,q0,v0,u0,qnext,vnext;ip_method=false,in_place=true,comp_scale=1.)
    contact_params = compute_contact_params(sim_data,q0,v0,u0,qnext,vnext)

    x, λ, μ = solve_implicit_contact_τ(sim_data,contact_params.ϕs,contact_params.Dtv,contact_params.rel_transforms,contact_params.geo_jacobians,contact_params.geo_jacobians_surfaces,
                                       contact_params.HΔv,contact_params.bias,contact_params.contact_x0,contact_params.contact_λ0,contact_params.contact_μ0,
                                       ip_method=ip_method,in_place=in_place,comp_scale=comp_scale)

    τ = τ_total(x,contact_params.rel_transforms,contact_params.geo_jacobians,contact_params.geo_jacobians_surfaces,sim_data)

    return τ, x, λ, μ
end

function solve_implicit_contact_τ_maxdiss(sim_data,q0,v0,u0,qnext,vnext;ip_method=false,in_place=true)
    contact_params = compute_contact_params(sim_data,q0,v0,u0,qnext,vnext)
    
    # sim_data,ϕs,rel_transforms,geo_jacobians,H,bias
    x, λ, μ = solve_implicit_contact_τ_maxdiss(sim_data,contact_params.ϕs,contact_params.Dtv,
                    contact_params.rel_transforms,contact_params.geo_jacobians,
                    contact_params.H,contact_params.bias,v0)

    τ = τ_total(x,contact_params.rel_transforms,contact_params.geo_jacobians,contact_params.geo_jacobians_surfaces,sim_data)

    return τ, x, λ, μ
end
