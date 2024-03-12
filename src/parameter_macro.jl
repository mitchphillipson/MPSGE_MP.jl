function _strip_value(nest)
    value = nest.args[2]
    if Meta.isexpr(value, :block)
        value = value.args[2]
    end
    return value
end

function _strip_nest_name(nest)
    parent = missing
    name = nest.args[1]
    if Meta.isexpr(name, :call)
        parent = name.args[3]
        name = name.args[2]
    end
    return parent, name
end

function _parse_nest(nest)
    if !Meta.isexpr(nest, :(=))
        error("Invalid syntax for nesting $nest. Required to have an = in "*
        "statement. `s = 0` or `va => s = 0`."
        )
    end
    value = _strip_value(nest)
    parent, name = _strip_nest_name(nest)

    return (parent, name, value)

end

function _parse_nests_to_dictionary(nestings)
    out = Dict()
    for (parent, name, value) ∈ _parse_nest.(nestings)
        if !haskey(out, name)
            out[name] = (elasticity = value, parent = parent)
        else
            error("Nest $name has already been used in this production block")
        end
    end
    return out

end



function _add_kw_args(call, kw_args)
    for kw in kw_args
        @assert Meta.isexpr(kw, :(=))
        push!(call.args, esc(Expr(:kw, kw.args...)))
    end
end


"""
    This feels bad. I steal the nest name directly from the netput macro.
    Feels fragile. 
"""
function _parse_netputs(netputs)
    out = Dict()
    for netput in netputs
        if !isa(netput, LineNumberNode)
            nest = netput.args[5]
            if !haskey(out,nest)
                out[nest] = []
            end
            push!(out[nest],netput)
        end
    end
    return out
end


macro Output(commodity, quantity, nest, kwargs...)
    constr_call = :(ScalarOutput($(esc(commodity)), $(esc(quantity))))
    _add_kw_args(constr_call, kwargs)
    return :($constr_call)
end


macro Input(commodity, quantity, nest, kwargs...)
    constr_call = :(ScalarInput($(esc(commodity)), $(esc(quantity))))
    _add_kw_args(constr_call, kwargs)
    return :($constr_call)
end


function construct_tree(nests, netputs; root = :t)
    sub_nests = [e for (e,info)∈nests if !ismissing(info[:parent]) && info[:parent] == root]
    children = Any[construct_tree(nests, netputs; root = name) for name in sub_nests] #Find/construct all the nests that have root as a parent
    append!(children, get(netputs, root,[])) # Add any netput leaves

    return :(ScalarNest($(QuoteNode(root)); elasticity = $(nests[root][:elasticity]), children = [$children...]))
end


macro _production(model, sector, nests, netputs)
    nest_dict = _parse_nests_to_dictionary(nests.args)
    netput_dict = _parse_netputs(netputs.args)

    output = construct_tree(nest_dict, netput_dict; root = :t)
    input = construct_tree(nest_dict, netput_dict; root = :s)
    
    constr_call = :(add_production!($(esc(model)), $(esc(sector)), [$output...], [$input...]))
    #_add_kw_args(constr_call, kwargs)
    
    return :($constr_call)
end



#=
M = MPSGEModel()

@parameter(M, tax, 0)
@parameter(M, σ, .5)
@parameter(M, id, 120)

@sectors(M,begin
    X
    Y
    W
end)

@commodities(M,begin
    PX
    PY
    PL
    PK
    PW
end)

@consumer(M, CONS);

@macroexpand @_production(M, X, [t = 0, s = 1, va => s = 1], begin
    @Output PX id t
    @Input PY 20 s
    @Input PL 40 va taxes = [Tax(CONS, tax)]
    @Input PL 60 va taxes = [Tax(CONS, tax)]
end)

=#