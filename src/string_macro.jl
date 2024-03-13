"""
    function blockify(mpsge::String)

First step in the MPSGE parser. Take GAMS-like MPSGE string and break 
into blocks.

Returns a dictionary with keys and word that starts with \$ in the 
input string and values vectors of the corresponding blocks as vectors.

For example, given input

\$Sector: X

\$Commodity: PX

\$Consumer: CONS

\$Prod:X s:.5
    O:PX Q:120

The output is:

Dict(
    "sector" => [["\$Sector: X"]],
    "commodity" => [["\$Commodity: PX"]],
    "consumer" => [["\$Consumer: CONS"]],
    "prod" => [["\$Prod:X s:.5","O:PX Q:120"]]
    )
"""
function blockify(mpsge::String)

    out = Dict()
    current = missing
    #Break the string into lines, dropping lines that are only whitespace.
    lines = [e for e in split(mpsge,'\n') if !occursin(r"^\s*$",e)]
    for line in lines
        m = match(r"^\$(\w*):",line) 
        if isnothing(m)
            push!(out[current][end],string(strip(line)))
        else
            current = lowercase(match(r"^\$(\w*):",line).captures[1])
            if current ∈ keys(out)
                push!(out[current],[line])
            else
                out[current] = [[string(line)]]
            end
        end
    end
    return out

end

###############
## Variables ##
###############

function parse_variable_line(L::AbstractString)
    L = strip(L)
    if occursin("!",L)
        line = split(L,"!")
        line = string.(strip.(line))
        var = parse_variable_line(line[1])
        return [merge(v,(description = join(line[2:end],"!"),)) for v∈var]
    else
        variables = [string(v) for v∈split(L,r"\s") if v!=""]
        #Here is where you can parse for a domain. Return a tuple with a domain key
        return [(variable = v,) for v∈variables]
    end
end

function parse_variable(S::Vector{String})
    variables = parse_variable_line.(S[2:end])
    return collect(Iterators.flatten(variables))
end

################
## Production ##
################

function find_production_sector(P::String)
    return string(match(r"\$\w*:\s*(\w+)(?:\s|)",P).captures[1])

end

function find_production_nests(P::String)

    nests = []
    "regex: space(at least one non-space):optional spaces (at least one non-space.)"
    for m in eachmatch(r"\s([\S]+):\s*(\S+)",P)
        push!(nests,Tuple(e for e in m.captures))
    end
    nests
end


    
function parse_line(line::String)


    out = []
    for m in eachmatch(r"\s([^\s:]+):\s*([^\s:]+)"," $line")
        push!(out,Tuple(e for e in m.captures))
    end
    return out
end


function parse_production_line(line::String,nest_list)

    if occursin(r"^I:",line)
        found_nests = ["s"]
    else
        found_nests = ["t"]
    end
    for nest in nest_list
        nest_regex = r"\s"*nest*r":"
        if contains(line, nest_regex)
            line = replace(line,nest_regex => "")
            push!(found_nests,nest)
        end

    end

    @assert length(found_nests)<=2 "Error: Too many nests found in $line"

    out = parse_line(line)

    (input,name) = out[1]

    @assert input ∈ ["I","O"] "Error in line $out. Must be (I)nput or (O)utput"

    input = input == "I" 

    (q,quantity) = out[2]

    @assert q == "Q" "Error in line $out. Must be (Q)uantity"

    quantity = parse(Float64,quantity)

    ####################################
    ## Look out for reference price!! ##
    ####################################

    ##############################################
    ## Currently assuming all taxes are numbers ##
    ## rather than expressions                  ##
    ##############################################

    taxes = []
    for ((a,agent),(t,tax)) ∈ zip(out[3:2:end],out[4:2:end])
        push!(taxes,(agent,parse(Float64,tax)))
    end

    inputs = (input = input, name = name, quantity = quantity, reference_price = 1,tax = taxes)

    return (nest = found_nests[end], inputs = inputs)
end

function parse_production(P::Vector{String})

    name = find_production_sector(P[1])

    nests = find_production_nests(P[1])
    
    """
        Nests may have (), get just the name to remove from
        the production lines.
    """
    nest_name(x) = occursin("(",x) ? string(split(x,'(')[1]) : x
    nest_list = [nest_name(a) for (a,b) ∈ nests]

    lines = parse_production_line.(P[2:end],Ref(nest_list))

    return (name = name, 
            nests = nests,
            parsed_lines = lines
    )

end

#############
## Demands ##
#############

function find_demand_sector(P::String)
    return string(match(r"\$\w*:\s*(\w+)(?:\s|)",P).captures[1])
end

function parse_demand_line(D::String)
    L = parse_line.(D)

    (demand,name) = L[1]

    @assert demand ∈ ["D","E"] "Demand $L must be either (D)emand or (E)ndowment"

    demand = demand=="D"

    (q,quantity) = L[2]

    @assert q == "Q" "Error in line $L. Must be (Q)uantity"

    quantity = parse(Float64,quantity)

    return (demand = demand,name = name, quantity=quantity,reference_price=1)

end

function parse_demand(D::Vector{String})
    name = find_demand_sector(D[1])

    lines = parse_demand_line.(D[2:end])
    return (name = name,lines = lines)
end


#############################
## Putting it all together ##
#############################

function parse_mpsge(M::String)
    blocks = blockify(M)

    sectors = parse_variable(blocks["sectors"][1])
    commodities = parse_variable(blocks["commodities"][1])
    consumers = parse_variable(blocks["consumers"][1])


    production = parse_production.(blocks["prod"])
    demand = parse_demand.(blocks["demand"])

    return (
        sectors = sectors,
        commodities = commodities,
        consumers = consumers,
        production = production,
        demand = demand
        )
end


###########
## Macro ##
###########

function parse_nest_name(name::AbstractString)
    reg_match = match(r"(.*)\((.*)\)",name)
    if isnothing(reg_match)
        return (name,missing)
    else
        a,b = reg_match.captures
        return (a,b)
    end
end

macro mpsge_str(input_mpsge)
    M = parse_mpsge(input_mpsge)
    
    return M

    #=
    model = Model(PATHSolver.Optimizer)

    mpsge = MPSGE(model,
        [Sector(s[:variable],model) for s∈M[:sectors]],
        [Commodity(s[:variable],model) for s∈M[:commodities]],
        [Consumer(s[:variable],model) for s∈M[:consumers]]
    )
    
    
    for P in M[:production]
    
        nodes = Dict()
        parent_flag = Dict("s" => true,"t"=>true)
        nodes["s"] = mpsge_tree(:s,0)
        nodes["t"] = mpsge_tree(:t,0)
    
        for (name,σ) ∈ P[:nests]
            (child,parent) = parse_nest_name(name)
            nodes[child] = mpsge_tree(Symbol(child),parse(Float64,σ))
            if !ismissing(parent)
                add_child!(nodes[parent],nodes[child])
                parent_flag[child] = true
            else
                if child ∉ keys(parent_flag)
                    parent_flag[child] = false
                end
                
            end
        end
    
        for line ∈ P[:parsed_lines]
            
            nest = line[:nest]
            inputs = line[:inputs]
            taxes =[(mpsge[name],q) for (name,q) in inputs[:tax]]
            tree = mpsge_tree(mpsge[inputs[:name]];quantity = inputs[:quantity],
                                                reference_price = inputs[:reference_price], 
                                                tax = taxes,
                                                input = inputs[:input])
            add_child!(nodes[nest],tree)
    
            if !parent_flag[nest]
                parent = inputs[:input] ? "s" : "t"
                add_child!(nodes[parent],nodes[nest])
                parent_flag[nest] = true
            end
        end
    
        update_quantities!(nodes["s"])
        update_quantities!(nodes["t"])
    
        push!(mpsge.products,Production(mpsge[P[:name]],nodes["s"],nodes["t"]))
    end
    
    
    for D∈M[:demand]
        demand = Demand(mpsge[D[:name]], 
                        [(mpsge[line[:name]],line[:quantity]) for line∈D[:lines] if line[:demand]],
                        [(mpsge[line[:name]],line[:quantity]) for line∈D[:lines] if !line[:demand]]
                    )
        push!(mpsge.demands,demand)
    end
    
    


    A = Containers.DenseAxisArray{Union{Float64,NonlinearExpr}}(undef,mpsge.commodities,mpsge.sectors)
    fill!(A,0.)

    for P in mpsge.products
        S = P.sector
        for (C,eqn) in find_path_to_leaves(P)
            A[C.name,S] = eqn
        end
    end

    taxes = Containers.DenseAxisArray{Float64}(undef,mpsge.commodities,mpsge.sectors,mpsge.consumers)
    fill!(taxes,0.)

    for P in mpsge.products
        for (commodity,tax) ∈ get_taxes(P)
            for (consumer,t) in tax
                taxes[commodity,P.sector,consumer] += t
            end
        end
    end

    tau = Containers.DenseAxisArray{Union{Float64,NonlinearExpr}}(undef,mpsge.sectors,mpsge.consumers)#,commodities)

    for s∈mpsge.sectors,h∈mpsge.consumers
        tau[s,h] = -sum(A[c,s]*taxes[c,s,h]*c.variable for c∈mpsge.commodities if taxes[c,s,h]>0;init=0.0);
    end

    endowments = Containers.DenseAxisArray{Float64}(undef,mpsge.consumers,mpsge.commodities)
    fill!(endowments,0)


    for demand in mpsge.demands
        consumer = demand.consumer
        for (commodity,endowment) in demand.endowments
            endowments[consumer,commodity] = endowment
        end
    end

    demands = Containers.DenseAxisArray{Union{Float64,NonlinearExpr}}(undef,mpsge.consumers,mpsge.commodities)
    fill!(demands,0.)

    for demand in mpsge.demands
        consumer = demand.consumer
        (commodity,quantity) = demand.demands[1]
        demands[consumer,commodity] = consumer.variable/commodity.variable
        set_start_value(consumer.variable,quantity)
    end

    @constraint(mpsge.model, zero_profit[s = mpsge.sectors],
        -sum(A[c,s]*c.variable for c∈mpsge.commodities) + sum(tau[s,h] for h∈mpsge.consumers) ⟂ s.variable
    )


    @constraint(mpsge.model, market_clearance[c= mpsge.commodities],
        sum(A[c,s]*s.variable for s∈mpsge.sectors) + sum(endowments[h,c] - demands[h,c] for h∈mpsge.consumers) ⟂ c.variable
    )


    @constraint(mpsge.model, income_balance[h = mpsge.consumers],
        h.variable - ( sum(endowments[h,c]*c.variable for c∈mpsge.commodities) + sum(tau[s,h]*s.variable for s∈mpsge.sectors)) ⟂ h.variable
    );




    return mpsge

    =#    
end