mutable struct TrajData
    Δt
    mechanism
    num_q
    num_v
    num_contacts
    β_dim
    world
    world_frame
    total_weight
    bodies
    contact_points
    obstacles
    μs
    paths
    Ds
    β_selector
    λ_selector
    c_n_selector
    N
    num_slack
    num_xn
    implicit_contact
    num_kin
    num_dyn
    num_comp
    num_dist
    num_pos
    num_dyn_eq
    num_dyn_ineq
    num_x
    num_eq
    num_ineq
    con
end

function add_constraint!(traj_data, con_fn, con_indx)
    push!(traj_data.con, (con_fn,con_indx))
    traj_data.num_eq += traj_data.num_q + traj_data.num_v
end

function get_traj_data(mechanism::Mechanism,
                       env::Environment,
                       Δt::Real,
                       N::Int,
                       implicit_contact::Bool)

    num_q = num_positions(mechanism)
    num_v = num_velocities(mechanism)
    num_contacts = length(env.contacts)
    if num_contacts > 0
        β_dim = length(contact_basis(env.contacts[1][3]))
    else
        β_dim = Int(0)
    end

    # some constants throughout the trajectory
    world = root_body(mechanism)
    world_frame = default_frame(world)
    total_weight = mass(mechanism) * norm(mechanism.gravitational_acceleration)
    bodies = []
    contact_points = []
    obstacles = []
    μs = []
    paths = []
    Ds = []
    for (body, contact_point, obstacle) in env.contacts
      push!(bodies, body)
      push!(contact_points, contact_point)
      push!(obstacles, obstacle)
      push!(μs, obstacle.μ)
      push!(paths, path(mechanism, body, world))
      push!(Ds, contact_basis(obstacle))
    end
    β_selector = findall(x->x!=0,repeat(vcat(ones(β_dim),[0,0]),num_contacts))
    λ_selector = findall(x->x!=0,repeat(vcat(zeros(β_dim),[1,0]),num_contacts))
    c_n_selector = findall(x->x!=0,repeat(vcat(zeros(β_dim),[0,1]),num_contacts))

    if implicit_contact
        num_slack = 0
        num_xn = num_q+num_v+num_slack+num_v
    else
        num_slack = 1
        num_xn = num_q+num_v+num_slack+num_contacts*(2+β_dim)+num_v
    end

    num_kin = num_q
    num_dyn = num_v
    num_comp = num_contacts*3
    num_dist = num_contacts
    num_pos = num_contacts*(1+β_dim)

    num_dyn_eq = num_kin+num_dyn
    num_dyn_ineq = num_comp+num_dist+num_pos

    num_x = N*num_xn
    num_eq = (N-1)*num_dyn_eq
    num_ineq = (N-1)*num_dyn_ineq

    con = Vector()

    traj_data = TrajData(Δt,mechanism,num_q,num_v,num_contacts,β_dim,
                         world,world_frame,total_weight,
                         bodies,contact_points,obstacles,μs,paths,Ds,
                         β_selector,λ_selector,c_n_selector,
                         N,num_slack,num_xn,implicit_contact,
                         num_kin,num_dyn,num_comp,num_dist,num_pos,
                         num_dyn_eq,num_dyn_ineq,num_x,num_eq,num_ineq,con)

    traj_data
end
