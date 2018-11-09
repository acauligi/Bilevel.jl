struct SimData
    Δt
    mechanism
    x0
    rel_transforms
    geo_jacobians
    num_q
    num_v
    num_contacts
    β_dim
    num_x
    num_h
    num_g
    world
    world_frame
    total_weight
    bodies
    contact_points
    obstacles
    contact_bases
    μs
    paths
    Ds
    slack_selector
    β_selector
    λ_selector
    c_n_selector
end

function update_constraints(sim_data,q0,v0,u0)
    set_configuration!(sim_data.x0,q0)
    set_velocity!(sim_data.x0,v0)
    setdirty!(sim_data.x0)
    H = mass_matrix(sim_data.x0)
    
    function eval_g(x::AbstractArray{T}, g) where T
        qnext = x[1:sim_data.num_q]
        vnext = x[sim_data.num_q+1:sim_data.num_q+sim_data.num_v]
        xnext = MechanismState{T}(sim_data.mechanism)
        set_configuration!(xnext, qnext)
        set_velocity!(xnext, vnext)
        
        ϕs = Vector{T}(sim_data.num_contacts)
        Dtv = Matrix{T}(sim_data.β_dim,sim_data.num_contacts)
        for i = 1:sim_data.num_contacts
            v = point_velocity(twist_wrt_world(xnext,sim_data.bodies[i]), transform_to_root(xnext, sim_data.contact_points[i].frame) * sim_data.contact_points[i])
            Dtv[:,i] = map(sim_data.contact_bases[i]) do d
                dot(transform_to_root(xnext, d.frame) * d, v)
            end
            sim_data.rel_transforms[i] = (relative_transform(xnext, sim_data.obstacles[i].contact_face.outward_normal.frame, sim_data.world_frame),
                                          relative_transform(xnext, sim_data.contact_points[i].frame, sim_data.world_frame))
            sim_data.geo_jacobians[i] = geometric_jacobian(xnext, sim_data.paths[i])
            ϕs[i] = separation(sim_data.obstacles[i], transform(xnext, sim_data.contact_points[i], sim_data.obstacles[i].contact_face.outward_normal.frame))
        end
        
        config_derivative = configuration_derivative(xnext)
        HΔv = H * (vnext - v0)
        dyn_bias = dynamics_bias(xnext)
        contact_bias = τ_total(x[sim_data.num_q+sim_data.num_v+1:end],sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,
                                 sim_data.num_v,sim_data.num_contacts,sim_data.β_dim,sim_data.bodies,sim_data.contact_points,sim_data.obstacles,sim_data.Ds,
                                 sim_data.world_frame,sim_data.total_weight,sim_data.rel_transforms,sim_data.geo_jacobians)
        bias = dyn_bias + contact_bias
        
        g[1:sim_data.num_q] = qnext .- q0 .- sim_data.Δt .* config_derivative # == 0
        g[sim_data.num_q+1:sim_data.num_q+sim_data.num_v] = HΔv .- sim_data.Δt .* (u0 .- bias) # == 0
                
        g[sim_data.num_q+sim_data.num_v+1:sim_data.num_q+sim_data.num_v+sim_data.num_contacts*(2+sim_data.β_dim)] = 
            complementarity_contact_constraints(x[sim_data.num_q+sim_data.num_v+1:end],ϕs,sim_data.μs,Dtv,
                                                  sim_data.slack_selector,sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,sim_data.β_dim,sim_data.num_contacts) # <= 0
            
        g[sim_data.num_q+sim_data.num_v+sim_data.num_contacts*(2+sim_data.β_dim)+1:sim_data.num_q+sim_data.num_v+sim_data.num_contacts*(2+sim_data.β_dim)+sim_data.num_contacts] = -ϕs # <= 0        
        
        g[sim_data.num_q+sim_data.num_v+sim_data.num_contacts*(2+sim_data.β_dim)+sim_data.num_contacts+1:sim_data.num_q+sim_data.num_v+sim_data.num_contacts*(2+sim_data.β_dim)+sim_data.num_contacts+sim_data.num_contacts*(3+2*sim_data.β_dim)] = 
            pos_contact_constraints(x[sim_data.num_q+sim_data.num_v+1:end],
                                      sim_data.num_contacts,sim_data.β_dim,
                                      sim_data.β_selector,sim_data.λ_selector,sim_data.c_n_selector,
                                      Dtv,sim_data.μs) # <= 0
    end
    
    function eval_jac_g(x, mode, rows, cols, values)
        if mode == :Structure
            # TODO actually figure out the sparsity pattern
            for i = 1:(sim_data.num_h + sim_data.num_g)
                for j = 1:sim_data.num_x
                    rows[(i-1)*sim_data.num_x+j] = i
                    cols[(i-1)*sim_data.num_x+j] = j
                end
            end
        else
            g = zeros(sim_data.num_h + sim_data.num_g)
            J = ForwardDiff.jacobian((g̃, x̃) -> eval_g(x̃, g̃), g, x)
            values[:] = J'[:]
        end
    end
    
    eval_g, eval_jac_g
end

function update_constraints_implicit_contact(sim_data,q0,v0,u0)    
    set_configuration!(sim_data.x0,q0)
    set_velocity!(sim_data.x0,v0)
    setdirty!(sim_data.x0)
    H = mass_matrix(sim_data.x0)
    
    function eval_g(x::AbstractArray{T}, g) where T
        qnext = x[1:sim_data.num_q]
        vnext = x[sim_data.num_q+1:sim_data.num_q+sim_data.num_v]
        xnext = MechanismState{T}(sim_data.mechanism)
        set_configuration!(xnext, qnext)
        set_velocity!(xnext, vnext)
        
        ϕs = Vector{T}(sim_data.num_contacts)
        Dtv = Matrix{T}(sim_data.β_dim,sim_data.num_contacts)
        for i = 1:sim_data.num_contacts
            v = point_velocity(twist_wrt_world(xnext,sim_data.bodies[i]), transform_to_root(xnext, sim_data.contact_points[i].frame) * sim_data.contact_points[i])
            Dtv[:,i] = map(sim_data.contact_bases[i]) do d
                dot(transform_to_root(xnext, d.frame) * d, v)
            end
            sim_data.rel_transforms[i] = (relative_transform(xnext, sim_data.obstacles[i].contact_face.outward_normal.frame, sim_data.world_frame),
                                          relative_transform(xnext, sim_data.contact_points[i].frame, sim_data.world_frame))
            sim_data.geo_jacobians[i] = geometric_jacobian(xnext, sim_data.paths[i])
            ϕs[i] = separation(sim_data.obstacles[i], transform(xnext, sim_data.contact_points[i], sim_data.obstacles[i].contact_face.outward_normal.frame))
        end
        
        config_derivative = configuration_derivative(xnext)
        HΔv = H * (vnext - v0)
        dyn_bias = dynamics_bias(xnext)
        contact_bias = solve_implicit_contact_τ(sim_data,ϕs,Dtv,HΔv,dyn_bias,q0,v0,u0,qnext,vnext)
        bias = dyn_bias + contact_bias
        
        g[1:sim_data.num_q] = qnext .- q0 .- sim_data.Δt .* config_derivative # == 0
        g[sim_data.num_q+1:sim_data.num_q+sim_data.num_v] = HΔv .- sim_data.Δt .* (u0 .- bias) # == 0
        g[sim_data.num_q+sim_data.num_v+1:sim_data.num_q+sim_data.num_v+sim_data.num_contacts] = -ϕs # <= 0
    end
    
    function eval_jac_g(x, mode, rows, cols, values)
        if mode == :Structure
            # TODO actually figure out the sparsity pattern
            for i = 1:(sim_data.num_h + sim_data.num_g)
                for j = 1:sim_data.num_x
                    rows[(i-1)*sim_data.num_x+j] = i
                    cols[(i-1)*sim_data.num_x+j] = j
                end
            end
        else
            g = zeros(sim_data.num_h + sim_data.num_g)
            J = ForwardDiff.jacobian((g̃, x̃) -> eval_g(x̃, g̃), g, x)
            values[:] = J'[:]
        end
    end
    
    eval_g, eval_jac_g
end

function simulate(state0::MechanismState{T, M},
                  env::Environment,
                  Δt::Real,
                  N::Integer;
                  implicit_contact=true) where {T, M}

    mechanism = state0.mechanism
    
    num_q = num_positions(state0)
    num_v = num_velocities(state0)
    num_contacts = length(env.contacts)
    β_dim = length(contact_basis(env.contacts[1][3]))
    # x = [q, v, slack, β1, λ1, c_n1, β2, λ2, c_n2...]
    if implicit_contact
        num_x = num_q + num_v
        num_g = num_contacts
    else
        num_x = num_q + num_v + 1 + num_contacts*(2+β_dim)
        num_g = num_contacts + num_contacts*(5+3*β_dim)
    end
    num_h = num_q + num_v
    
    # some constants throughout the simulation
    world = root_body(mechanism)
    world_frame = default_frame(world)
    total_weight = mass(mechanism) * norm(mechanism.gravitational_acceleration)
    bodies = []
    contact_points = []
    obstacles = []
    contact_bases = []
    μs = []
    paths = []
    Ds = []
    for (body, contact_point, obstacle) in env.contacts
        push!(bodies, body)
        push!(contact_points, contact_point)
        push!(obstacles, obstacle)
        push!(contact_bases, contact_basis(obstacle))
        push!(μs, obstacle.μ)
        push!(paths, path(mechanism, body, world))
        push!(Ds, contact_basis(obstacle))
    end
    slack_selector = [1]
    β_selector = find(vcat(0,repmat(vcat(ones(β_dim),[0,0]),num_contacts)))
    λ_selector = find(vcat(0,repmat(vcat(zeros(β_dim),[1,0]),num_contacts)))
    c_n_selector = find(vcat(0,repmat(vcat(zeros(β_dim),[0,1]),num_contacts)))
    
    x0 = MechanismState(mechanism)
    rel_transforms = Vector{Tuple{Transform3D, Transform3D}}(num_contacts) # force transform, point transform
    geo_jacobians = Vector{GeometricJacobian}(num_contacts)
    
    sim_data = SimData(Δt,mechanism,x0,rel_transforms,geo_jacobians,
                       num_q,num_v,num_contacts,β_dim,num_x,num_h,num_g,
                       world,world_frame,total_weight,
                       bodies,contact_points,obstacles,contact_bases,μs,paths,Ds,
                       slack_selector,β_selector,λ_selector,c_n_selector)

    # optimization bounds
    x_L = -1e19 * ones(num_x)
    x_U = 1e19 * ones(num_x)
    
    g_L = vcat(0. * ones(num_h), -1e19 * ones(num_g))
    g_U = vcat(0. * ones(num_h),    0. * ones(num_g)) 

    # null costs for simulation
    if implicit_contact
        results = vcat(configuration(state0),velocity(state0))
        eval_f = x -> 0.
        eval_grad_f = (x, grad_f) -> grad_f[:] = 0.
    else 
        results = vcat(configuration(state0),velocity(state0),zeros(length(slack_selector)+num_contacts*(2+β_dim)))
        eval_f = x -> .5*x[num_q+num_v+1]^2
        eval_grad_f = (x, grad_f) -> begin 
            grad_f[:] = 0.
            grad_f[num_q+num_v+1] = x[num_q+num_v+1]
        end
    end
    
    for i in 1:N
      x = results[:,end]
      q0 = x[1:num_q]
      v0 = x[num_q+1:num_q+num_v]
      u0 = zeros(num_v) # for now no controller
      
      if implicit_contact
          eval_g, eval_jac_g = update_constraints_implicit_contact(sim_data,q0,v0,u0)
      else
          eval_g, eval_jac_g = update_constraints(sim_data,q0,v0,u0)
      end
      
      prob = createProblem(num_x,x_L,x_U,
                           num_h+num_g,g_L,g_U,
                           num_x*(num_h+num_g),0,
                           eval_f,eval_g,
                           eval_grad_f,eval_jac_g)
                           
      prob.x[:] = results[:,end][:]
      
      addOption(prob, "hessian_approximation", "limited-memory")
      addOption(prob, "print_level", 0)              
      
      status = solveProblem(prob)
      println(Ipopt.ApplicationReturnStatus[status])
      
      results = hcat(results,prob.x)
    end

    results
end