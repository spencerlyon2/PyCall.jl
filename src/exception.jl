#########################################################################
# Wrapper around Python exceptions

type PyError <: Exception
    msg::AbstractString # message string from Julia context, or "" if none

    # info returned by PyErr_Fetch/PyErr_Normalize
    T::PyObject
    val::PyObject
    traceback::PyObject

    # generate a PyError object.  Should normally only be called when
    # PyErr_Occurred returns non-NULL, and clears the Python error
    # indicator.  Assumes Python is initialized!
    function PyError(msg::AbstractString)
        exc = Array(PyPtr, 3)
        pexc = convert(Uint, pointer(exc))
        # equivalent of passing C pointers &exc[1], &exc[2], &exc[3]:
        ccall((@pysym :PyErr_Fetch), Void, (Uint,Uint,Uint),
              pexc, pexc + sizeof(PyPtr), pexc + 2*sizeof(PyPtr))
        ccall((@pysym :PyErr_NormalizeException), Void, (Uint,Uint,Uint),
              pexc, pexc + sizeof(PyPtr), pexc + 2*sizeof(PyPtr))
        new(msg, exc[1], exc[2], exc[3])
    end
end

function show(io::IO, e::PyError)
    print(io, "PyError",
          isempty(e.msg) ? e.msg : string(" (",e.msg,")"),
          " ")

    if e.T.o == C_NULL
        println(io, "None")
    else
        println(io, pystring(e.T), "\n", pystring(e.val))
    end
    
    if e.traceback.o != C_NULL
        o = pycall(format_traceback, PyObject, e.traceback)
        if o.o != C_NULL
            for s in PyVector{AbstractString}(o)
                print(io, s)
            end
        end
    end
end

#########################################################################
# Conversion of Python exceptions into Julia exceptions

# call to discard Python exceptions
pyerr_clear() = ccall((@pysym :PyErr_Clear), Void, ())

function pyerr_check(msg::AbstractString, val::Any)
    # note: don't call pyinitialize here since we will
    # only use this in contexts where initialization was already done
    if ccall((@pysym :PyErr_Occurred), PyPtr, ()) != C_NULL
        throw(PyError(msg))
    end
    val # the val argument is there just to pass through to the return value
end

pyerr_check(msg::AbstractString) = pyerr_check(msg, nothing)
pyerr_check() = pyerr_check("")

# extract function name from ccall((@pysym :Foo)...) or ccall(:Foo,...) exprs
callsym(s::Symbol) = s
callsym(s::QuoteNode) = s.value
import Base.Meta.isexpr
callsym(ex::Expr) = isexpr(ex,:macrocall,2) ? callsym(ex.args[2]) : isexpr(ex,:ccall) ? callsym(ex.args[1]) : ex

# Macros for common pyerr_check("Foo", ccall((@pysym :Foo), ...)) pattern.
# (The "i" variant assumes Python is initialized.)
macro pychecki(ex)
    :(pyerr_check($(string(callsym(ex))), $ex))
end
macro pycheck(ex)
    quote
        @pyinitialize
        @pychecki $ex
    end
end

# Macros to check that ccall((@pysym :Foo), ...) returns value != bad
# (The "i" variants assume Python is initialized.)
macro pycheckvi(ex, bad)
    quote
        val = $ex
        if val == $bad
            # throw a PyError if available, otherwise throw ErrorException
            pyerr_check($(string(callsym(ex))))
            error($(string(callsym(ex))), " failed")
        end
        val
    end
end
macro pycheckni(ex)
    :(@pycheckvi $ex C_NULL)
end
macro pycheckzi(ex)
    :(@pycheckvi $ex -1)
end
macro pycheckv(ex, bad)
    quote
        @pyinitialize
        @pycheckvi $ex $bad
    end
end
macro pycheckn(ex)
    quote
        @pyinitialize
        @pycheckni $ex
    end
end
macro pycheckz(ex)
    quote
        @pyinitialize
        @pycheckzi $ex
    end
end

#########################################################################
# Mapping of Julia Exception types to Python exceptions

const pyexc = Dict{DataType, PyPtr}()
type PyIOError <: Exception end

function pyexc_initialize()
    exc = @compat Dict(Exception => :PyExc_RuntimeError,
                       ErrorException => :PyExc_RuntimeError,
                       SystemError => :PyExc_SystemError,
                       TypeError => :PyExc_TypeError,
                       ParseError => :PyExc_SyntaxError,
                       ArgumentError => :PyExc_ValueError,
                       KeyError => :PyExc_KeyError,
                       LoadError => :PyExc_ImportError,
                       MethodError => :PyExc_RuntimeError,
                       EOFError => :PyExc_EOFError,
                       BoundsError => :PyExc_IndexError,
                       DivideError => :PyExc_ZeroDivisionError,
                       DomainError => :PyExc_RuntimeError,
                       OverflowError => :PyExc_OverflowError,
                       InexactError => :PyExc_ArithmeticError,
                       MemoryError => :PyExc_MemoryError,
                       StackOverflowError => :PyExc_MemoryError,
                       UndefRefError => :PyExc_RuntimeError,
                       InterruptException => :PyExc_KeyboardInterrupt,
                       PyIOError => :PyExc_IOError)
    for (k,v) in exc
        p = convert(Ptr{PyPtr}, pysym_e(v))
        if p != C_NULL
            pyexc[k] = unsafe_load(p)
        end
    end
end

function pyexc_finalize()
    empty!(pyexc)
end

function pyraise(e)
    eT = typeof(e)
    pyeT = haskey(pyexc::Dict, eT) ? pyexc[eT] : pyexc[Exception]
    ccall((@pysym :PyErr_SetString), Void, (PyPtr, Ptr{Uint8}),
          pyeT, bytestring(string("Julia exception: ", e)))
end

function pyraise(e::PyError)
    ccall((@pysym :PyErr_Restore), Void, (PyPtr, PyPtr, PyPtr),
          e.T, e.val, e.traceback)
    e.T.o = e.val.o = e.traceback.o = C_NULL # refs were stolen
end
