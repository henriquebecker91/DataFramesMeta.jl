module DataFramesMeta

importall Base
importall DataFrames
using DataFrames

# Basics:
export @with, @ix, @where, @orderby, @transform, @by, @based_on, @select
export where, orderby, transform, select

include("compositedataframe.jl")
include("linqmacro.jl")
include("byrow.jl")


##############################################################################
##
## @with
##
##############################################################################

replace_syms(x, membernames) = x
function replace_syms(e::Expr, membernames)
    if e.head == :call && length(e.args) == 2 && e.args[1] == :^
        return e.args[2]
    elseif e.head == :.     # special case for :a.b
        return Expr(e.head, replace_syms(e.args[1], membernames),
                            typeof(e.args[2]) == Expr && e.args[2].head == :quote ? e.args[2] : replace_syms(e.args[2], membernames))
    elseif e.head == :call && length(e.args) == 2 && e.args[1] == :_I_
        nam = :($(e.args[2]))
        if haskey(membernames, nam)
            return membernames[nam]
        else
            a = gensym()
            membernames[nam] = a
            return a
        end
    elseif e.head != :quote
        return Expr(e.head, (isempty(e.args) ? e.args : map(x -> replace_syms(x, membernames), e.args))...)
    else
        nam = Meta.quot(e.args[1])
        if haskey(membernames, nam)
            return membernames[nam]
        else
            a = gensym()
            membernames[nam] = a
            return a
        end
    end
end

function with_helper(d, body)
    membernames = Dict{Any, Symbol}()
    body = replace_syms(body, membernames)
    funargs = map(x -> :( getindex($d, $x) ), collect(keys(membernames)))
    funname = gensym()
    return(:( function $funname($(collect(values(membernames))...)) $body end; $funname($(funargs...)) ))
end

"""
`@with` allows DataFrame columns or Associative keys to be referenced as symbols

### Constructors

```julia
@with(d, expr)
```

### Arguments

* `d` : an AbstractDataFrame or Associative type 
* `expr` : the expression to evaluate in `d`

### Details

`@with` works by parsing the expression body for all columns indicated
by symbols (e.g. `:colA`). Then, a function is created that wraps the
body and passes the columns as function arguments. This function is
then called. Operations are efficient because:

- A pseudo-anonymous function is defined, so types are stable.
- Columns are passed as references, eliminating DataFrame indexing.

The following

```julia
@with(d, :a + :b + 1)
```

becomes

```julia
tempfun(a,b) = a + b + 1
tempfun(d[:a], d[:b])
```

All of the other DataFramesMeta macros are based on `@with`.

If an expression is wrapped in `^(expr)`, `expr` gets passed through untouched.
If an expression is wrapped in  `_I_(expr)`, the column is referenced by the
variable `expr` rather than a symbol. 

### Examples

```julia
y = 3
d = Dict(:s => 3, :y => 44, :d => 5)

@with(d, :s + :y + y)

df = DataFrame(x = 1:3, y = [2, 1, 2])
x = [2, 1, 0]

@with(df, :y + 1)
@with(df, :x + x)  # the two x's are different

x = @with df begin
    res = 0.0
    for i in 1:length(:x)
        res += :x[i] * :y[i]
    end
    res
end

@with(df, df[:x .> 1, ^(:y)]) # The ^ means leave the :y alone

colref = :x
@with(df, :y + _I_(colref)) # Equivalent to df[:y] + df[colref]

```

"""
macro with(d, body)
    esc(with_helper(d, body))
end


##############################################################################
##
## @ix - row and row/col selector
##
##############################################################################

ix_helper(d, arg) = :( let d = $d; $d[@with($d, $arg),:]; end )
ix_helper(d, arg, moreargs...) = :( let d = $d; getindex(d, @with(d, $arg), $(moreargs...)); end )

"""
Select row and/or columns. This is an alternative to `getindex`.

### Constructors

```julia
@ix(d, i)      # select rows
@ix(d, i, j)   # select rows and columns
```

### Arguments

* `d` : an AbstractDataFrame
* `i` : expression for selecting rows
* `j` : any column selector used in DataFrames

### Examples

```julia
df = DataFrame(x = 1:3, y = [2, 1, 2])
x = [2, 1, 0]

@ix(df, :x .> 1)
@ix(df, :x .> x) # again, the x's are different
@ix(df, :x .> 1, [:x])
```

"""
macro ix(d, args...)
    esc(ix_helper(d, args...))
end


##############################################################################
##
## @where - select row subsets
##
##############################################################################

where(d::AbstractDataFrame, arg) = d[arg, :]
where(d::AbstractDataFrame, f::Function) = d[f(d), :]
where(g::GroupedDataFrame, f::Function) = g[Bool[f(x) for x in g]]

collect_ands(x::Expr) = x
collect_ands(x::Expr, y::Expr) = :($x & $y)
collect_ands(x::Expr, y...) = :($x & $(collect_ands(y...)))

where_helper(d, args...) = :( where($d, _DF -> @with(_DF, $(collect_ands(args...)))) )

"""
Select row subsets in AbstractDataFrames or groups in GroupedDataFrames.

### Constructors

```julia
@where(d, i...)
```

### Arguments

* `d` : an AbstractDataFrame or GroupedDataFrame
* `i...` : expression for selecting rows

Multiple `i` expressions are "and-ed" together.

### Examples

```julia
df = DataFrame(x = 1:3, y = [2, 1, 2])
x = [2, 1, 0]

@where(df, :x .> 1)
@where(df, :x .> x)
@where(df, :x .> x, :y .== 3)

d = DataFrame(n = 1:20, x = [3, 3, 3, 3, 1, 1, 1, 2, 1, 1, 2, 1, 1, 2, 2, 2, 3, 1, 1, 2])
g = groupby(d, :x)
@where(d, :x .== 3)
@where(g, length(:x) > 5))   # pick out some groups
```
"""
macro where(d, args...)
    esc(where_helper(d, args...))
end


##############################################################################
##
## select - select columns
##
##############################################################################

select(d::AbstractDataFrame, arg) = d[ arg]


##############################################################################
##
## @orderby
##
##############################################################################

function orderby(d::AbstractDataFrame, args...)
    D = typeof(d)(args...)
    d[sortperm(D), :]
end
orderby(d::AbstractDataFrame, f::Function) = d[sortperm(f(d)), :]
orderby(g::GroupedDataFrame, f::Function) = g[sortperm([f(x) for x in g])]
orderbyconstructor(d::AbstractDataFrame) = (x...) -> DataFrame(Any[x...])
orderbyconstructor(d) = x -> x

"""
Sort by criteria. Normally used to sort groups in GroupedDataFrames.

### Constructors

```julia
@orderby(d, i...)
```

### Arguments

* `d` : an AbstractDataFrame or GroupedDataFrame
* `i...` : expression for sorting

The variable `_DF` can be used in expressions to refer to the whole DataFrame.

### Examples

```julia
d = DataFrame(n = 1:20, x = [3, 3, 3, 3, 1, 1, 1, 2, 1, 1, 2, 1, 1, 2, 2, 2, 3, 1, 1, 2])
g = groupby(d, :x)
orderby(g, x -> mean(x[:n]))
```

"""
macro orderby(d, args...)
    # I don't esc just the input because I want _DF to be visible to the user
    esc(:(let _D = $d;  DataFramesMeta.orderby(_D, _DF -> DataFramesMeta.@with(_DF, DataFramesMeta.orderbyconstructor(_D)($(args...)))); end))
end


##############################################################################
##
## transform & @transform
##
##############################################################################

function transform(d::Union{AbstractDataFrame, Associative}; kwargs...)
    result = copy(d)
    for (k, v) in kwargs
        result[k] = isa(v, Function) ? v(d) : v
    end
    return result
end

function transform(g::GroupedDataFrame; kwargs...)
    result = DataFrame(g)
    idx2 = cumsum(Int[size(g[i],1) for i in 1:length(g)])
    idx1 = [1; 1 + idx2[1:end-1]]
    for (k, v) in kwargs
        first = v(g[1])
        result[k] = Array(eltype(first), size(result, 1))
        result[idx1[1]:idx2[1], k] = first
        for i in 2:length(g)
            result[idx1[i]:idx2[i], k] = v(g[i])
        end
    end
    return result
end


function transform_helper(x, args...)
    # convert each kw arg value to: _DF -> @with(_DF, arg)
    newargs = [args...]
    for i in 1:length(args)
        newargs[i].args[2] = :( _DF -> @with(_DF, $(newargs[i].args[2]) ) )
    end
    :( transform($x, $(newargs...)) )
end

"""
Add additional columns or keys based on keyword arguments.

### Constructors

```julia
@transform(d, i...)
```

### Arguments

* `d` : an Associative type, AbstractDataFrame, or GroupedDataFrame
* `i...` : keyword arguments defining new columns or keys

For Associative types, `@transform` only works with keys that are symbols.

### Returns

* `::AbstractDataFrame`, `::Associative`, or `::GroupedDataFrame`

### Examples

```julia
d = Dict(:s => 3, :y => 44, :d => 5)
@transform(d, x = :y + :d)

df = DataFrame(A = 1:3, B = [2, 1, 2])
@transform(df, a = 2 * :A, x = :A + :B)
```

"""
macro transform(x, args...)
    esc(transform_helper(x, args...))
end



##############################################################################
##
## @based_on - summarize a grouping operation
##
##############################################################################

"""
Summarize a grouping operation

### Constructors

```julia
@based_on(g, i...)
```

### Arguments

* `g` : a GroupedDataFrame
* `i...` : keyword arguments defining new columns

### Examples

```julia
d = DataFrame(n = 1:20, x = [3, 3, 3, 3, 1, 1, 1, 2, 1, 1, 2, 1, 1, 2, 2, 2, 3, 1, 1, 2])
g = groupby(d, :x)
@based_on(g, nsum = sum(:n))
@based_on(g, x2 = 2 * :x, nsum = sum(:n))
```
"""
macro based_on(x, args...)
    # esc(:( DataFrames.based_on($x, _DF -> DataFramesMeta.@with(_DF, DataFrames.DataFrame($(args...)))) ))
    esc(:( DataFrames.combine(map(_DF -> DataFramesMeta.@with(_DF, DataFrames.DataFrame($(args...))), $x)) ))
end


##############################################################################
##
## @by - grouping
##
##############################################################################

"""
Split-apply-combine in one step

```julia
@by(d::AbstractDataFrame, cols, e...)
```

### Arguments

* `d` : an AbstractDataFrame
* `cols` : a column indicator (Symbol, Int, Vector{Symbol}, etc.)
* `e` :  keyword arguments specifying new columns in terms of column groupings

### Returns

* `::DataFrame` 

### Examples

```julia
df = DataFrame(a = rep(1:4, 2), b = rep(2:-1:1, 4), c = randn(8))
@by(df, :a, d = sum(:c))
@by(df, :a, d = 2 * :c)
@by(df, :a, c_sum = sum(:c), c_mean = mean(:c))
@by(df, :a, c = :c, c_mean = mean(:c))
```
"""
macro by(x, what, args...)
    esc(:( DataFrames.by($x, $what, _DF -> DataFramesMeta.@with(_DF, DataFrames.DataFrame($(args...)))) ))
end


##############################################################################
##
## @select - select and transform columns
##
##############################################################################

expandargs(x) = x

function expandargs(e::Expr)
    if e.head == :quote && length(e.args) == 1
        return Expr(:kw, e.args[1], Expr(:quote, e.args[1]))
    else
        return e
    end
end

function expandargs(e::Tuple)
    res = [e...]
    for i in 1:length(res)
        res[i] = expandargs(e[i])
    end
    return res
end

function select(d::Union{AbstractDataFrame, Associative}; kwargs...)
    result = typeof(d)()
    for (k, v) in kwargs
        result[k] = v
    end
    return result
end

"""
Select and transform columns

```julia
@select(d, e...)
```

### Arguments

* `d` : an AbstractDataFrame or Associative
* `e` :  keyword arguments specifying new columns in terms of existing columns 
  or symbols to specify existing columns

### Returns

* `::AbstractDataFrame` or `::Associative` 

### Examples

```julia
d = Dict(:s => 3, :y => 44, :d => 5)
@select(d, x = :y + :d, :s)

df = DataFrame(a = rep(1:4, 2), b = rep(2:-1:1, 4), c = randn(8))
@select(df, :c, :a)
@select(df, :c, x = :b + :c)
```
"""
macro select(x, args...)
    esc(:(let _DF = $x; DataFramesMeta.@with(_DF, select(_DF, $(DataFramesMeta.expandargs(args)...))); end))
end


##############################################################################
##
## Extras for GroupedDataFrames
##
##############################################################################

combnranges(starts, ends) = [[starts[i]:ends[i] for i in 1:length(starts)]...;]

DataFrame(g::GroupedDataFrame) = g.parent[g.idx[combnranges(g.starts, g.ends)], :]

Base.getindex(gd::GroupedDataFrame, I::AbstractArray{Int}) = GroupedDataFrame(gd.parent,
                                                                              gd.cols,
                                                                              gd.idx,
                                                                              gd.starts[I],
                                                                              gd.ends[I])


##############################################################################
##
## Extras for easier handling of Arrays
##
##############################################################################

export P, PassThrough

type PassThrough{T} <: AbstractVector{T}
    x::AbstractVector{T}
end
const P = PassThrough
size(x::PassThrough) = size(x.x)
getindex(x::PassThrough, i) = getindex(x.x, i)

DataFrames.upgrade_vector(v::PassThrough) = v.x

end # module
