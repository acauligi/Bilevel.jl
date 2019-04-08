function get_sim_data_direct(mechanism::Mechanism,env::Environment,Δt::Real)
    num_contacts = length(env.contacts)

    vs = VariableSelector()
    add_var!(vs, :qnext, num_positions(mechanism))
    add_var!(vs, :vnext, num_velocities(mechanism))
    for i = 1:num_contacts
        add_var!(vs, Symbol("c_n", i), 1)
    end

    cs = ConstraintSelector()
    add_eq!(cs, :kin, num_positions(mechanism))
    add_eq!(cs, :dyn, num_velocities(mechanism))
    for i = 1:num_contacts
        add_ineq!(cs, Symbol("ϕ_pos", i), 1)
        add_ineq!(cs, Symbol("c_n_pos", i), 1)
        add_eq!(cs, Symbol("ϕ_c_n_comp", i), 1)
    end
    
    x0_cache = StateCache(mechanism)
    xn_cache = StateCache(mechanism)
    envj_cache = EnvironmentJacobianCache(env)

    generate_solver_fn = :generate_solver_fn_sim_direct

    lower_vs = VariableSelector()
    for i = 1:length(env.contacts)
        β_dim = size(env.contacts[i].obstacle.basis,2)
        add_var!(lower_vs, Symbol("β", i), β_dim)
    end

    lower_cs = ConstraintSelector()
    for i = 1:length(env.contacts)
        β_dim = size(env.contacts[i].obstacle.basis,2)
        add_ineq!(lower_cs, Symbol("β_pos", i), β_dim)
        add_ineq!(lower_cs, Symbol("fric_cone", i), 1)
    end
   
    lower_options = Dict{String, Any}()
    lower_options["num_fosteps"] = 1
    lower_options["num_sosteps"] = 1
    lower_options["c"] = 1.
    lower_options["c_fos"] = 1.
    lower_options["c_sos"] = 1.
    
    SimData(mechanism,env,
            x0_cache,xn_cache,envj_cache,
            Δt,vs,cs,generate_solver_fn,
            lower_vs,lower_cs,lower_options)
end

function contact_τ_direct!(τ,sim_data::SimData,H,envj::EnvironmentJacobian,
                           dyn_bias,u0,v0,upper_x::AbstractArray{U}) where U  
    num_contacts = length(sim_data.env.contacts)
    Hi = inv(H)
    env = sim_data.env
    upper_vs = sim_data.vs
    lower_vs = sim_data.lower_vs
    lower_cs = sim_data.lower_cs

    Qds = []
    rds = []
    for i = 1:num_contacts
        Qd = sim_data.Δt*envj.contact_jacobians[i].J'*Hi*envj.contact_jacobians[i].J
        rd = envj.contact_jacobians[i].J'*(sim_data.Δt*Hi*(dyn_bias - u0) - v0)

        push!(Qds,Qd)
        push!(rds,rd)
    end

    function eval_obj_(x::AbstractArray{L}) where L
        obj = 0.

        for i = 1:num_contacts            
            z = vcat(upper_vs(upper_x, Symbol("c_n", i)),lower_vs(x, Symbol("β", i)))
            obj += .5 * z' * Qds[i] * z + rds[i]' * z
        end

        obj
    end

    function eval_cons_(x::AbstractArray{L}) where L
        # TODO in-place, need to accomodate x and upper_x types
        # g = Vector{L}(undef, lower_cs.num_eqs + lower_cs.num_ineqs)
        g = []

        for i = 1:num_contacts
            β = lower_vs(x, Symbol("β", i))
            # g[lower_cs(Symbol("β_pos", i))] .= -β
            # g[lower_cs(Symbol("fric_cone", i))] .= sum(β) - env.contacts[i].obstacle.μ * upper_vs(upper_x, Symbol("c_n", i))
            # TODO lucky this is all inequalities or indexing could break
            g = vcat(g, -β)
            g = vcat(g, sum(β) - env.contacts[i].obstacle.μ * upper_vs(upper_x, Symbol("c_n", i)))
        end
        
        g
    end

    fres = DiffResults.HessianResult(zeros(U, lower_vs.num_vars))
    gres = DiffResults.JacobianResult(zeros(U, lower_cs.num_cons), zeros(U, lower_vs.num_vars))
    solver_fn_ = generate_autodiff_solver_fn(eval_obj_,fres,eval_cons_,gres,lower_cs.eqs,lower_cs.ineqs)

    x0 = zeros(lower_vs.num_vars)

    xopt, info = auglag(solver_fn_, lower_cs.num_eqs, lower_cs.num_ineqs, x0, sim_data.lower_options)
    
    τ .= mapreduce(+, enumerate(envj.contact_jacobians)) do (i,cj)
        contact_τ(cj, upper_vs(upper_x, Symbol("c_n", i)), lower_vs(xopt, Symbol("β", i)))
    end
end

function generate_solver_fn_sim_direct(sim_data,q0,v0,u0)
    x0 = sim_data.x0_cache[Float64]
    Δt = sim_data.Δt
    vs = sim_data.vs
    cs = sim_data.cs
    
    num_contacts = length(sim_data.env.contacts)
    num_vel = num_velocities(sim_data.mechanism)

    set_configuration!(x0, q0)
    set_velocity!(x0, v0)
    H = mass_matrix(x0)
    
    function eval_obj(x::AbstractArray{T}) where T
        f = 0.
    
        f
    end

    function eval_cons(x::AbstractArray{T}) where T
        xn = sim_data.xn_cache[T]
        envj = sim_data.envj_cache[T]
        
        contact_bias = Vector{T}(undef, num_vel)
        g = Vector{T}(undef, cs.num_eqs + cs.num_ineqs) # TODO preallocate

        qnext = vs(x, :qnext)
        vnext = vs(x, :vnext)
        
        set_configuration!(xn, qnext)
        set_velocity!(xn, vnext)
        
        config_derivative = configuration_derivative(xn) # TODO preallocate
        dyn_bias = dynamics_bias(xn) # TODO preallocate
        if (num_contacts > 0)
            contact_jacobian!(envj, xn)
            contact_τ_direct!(contact_bias, sim_data, H, envj, dyn_bias, u0, v0, x)
        end

        g[cs(:kin)] .= qnext .- q0 .- Δt .* config_derivative
        g[cs(:dyn)] .= H * (vnext - v0) .- Δt .* (u0 .- dyn_bias .- contact_bias)
        for i = 1:num_contacts
            c_n = vs(x, Symbol("c_n", i))
            g[cs(Symbol("ϕ_pos", i))] .= -envj.contact_jacobians[i].ϕ
            g[cs(Symbol("c_n_pos", i))] .= -c_n
            g[cs(Symbol("ϕ_c_n_comp", i))] .= envj.contact_jacobians[i].ϕ .* c_n
        end

        g
    end
    
    generate_autodiff_solver_fn(eval_obj,eval_cons,cs.eqs,cs.ineqs,vs.num_vars)
end