#unum-unum.jl

#contains information about the unum type and helper functions directly related to constructor.

#the unum type is an abstract type.  We'll be overloading the call function later
#so we can do "pseudo-constructions" on this type.
doc"""
`Unum{ESS,FSS}` creates a Unum with esizesize ESS and fsizesize FSS.

NB:  Internally this may cast to a different Unum type (UnumLarge or UnumSmall)
for performance purposes.  The Unum{ESS,FSS}(...) constructor may be unsafe and
for safety-critical purposes, the corresponding unum(...) constructors or the
@unum macro is recommended.
"""
abstract Unum{ESS, FSS} <: Utype
export Unum

#general parameter checking for unums.
function __general_unum_checking(ESS, FSS, fsize, esize, flags, fraction, exponent)
  (ESS > 6) && throw(ArgumentError("ESS == $ESS > 6 disallowed in current implementation"))
  (FSS > 11) && throw(ArgumentError("FSS == $FSS > 11 disallowed in current implementation"))
  _mfs = max_fsize(FSS)
  (fsize > _mfs) && throw(ArgumentError("fsize == $fsize > $_mfs maximum for FSS == $FSS."))
  _mes = max_esize(ESS)
  (esize > _mes) && throw(ArgumentError("esize == $esize > $_mes maximum for ESS == $ESS."))
  _mbe = max_biased_exponent(esize)
  (exponent > _mbe) && throw(ArgumentError("exponent == $exponent > $_mbs maximum for esize == $esize."))
  #check to see that the fraction contents match.
  (FSS < 7) && (!isa(fraction, Uint64)) && throw(ArgumentError("FSS == $FSS requires a Uint64 fraction"))
  (FSS > 6) && (!isa(fraction, ArrayNum{FSS})) && throw(ArgumentError("FSS == $FSS requires a ArrayNum{$FSS} fraction"))
  nothing
end

type UnumSmall{ESS, FSS} <: Unum{ESS, FSS}
  fsize::UInt16
  esize::UInt16
  flags::UInt16
  fraction::UInt64
  exponent::UInt64
  @dev_check ESS FSS function UnumSmall(fsize, esize, flags, fraction, exponent)
    new(fsize, esize, flags, fraction, exponent)
  end
end

#unsafe copy constructor
UnumSmall{ESS,FSS}(x::UnumSmall{ESS,FSS}) = UnumSmall{ESS,FSS}(x.fsize, x.esize, x.flags, x.fraction, x.exponent)
UnumSmall{ESS,FSS}(x::UnumSmall{ESS,FSS}, flags::UInt16) = UnumSmall{ESS,FSS}(x.fsize, x.esize, flags, x.fraction, x.exponent)

#parameter checking.  The call to this check is autogenerated by the @dev_check macro
function __check_UnumSmall(ESS, FSS, fsize, esize, flags, fraction, exponent)
  __general_unum_check(ESS, FSS, fsize, esize, flags, fraction, exponent)
  (FSS > 6) && throw(ArgumentError("UnumSmall internal class is inappropriate for FSS == $FSS > 6."))
  nothing
end

type UnumLarge{ESS, FSS} <: Unum{ESS, FSS}
  fsize::UInt16
  esize::UInt16
  flags::UInt16
  fraction::ArrayNum{FSS}
  exponent::UInt64
  @dev_check ESS FSS function UnumLarge(fsize, esize, flags, fraction, exponent)
    new(fsize, esize, flags, fraction, exponent)
  end
end

#unsafe copy constructors
UnumLarge{ESS,FSS}(x::UnumSmall{ESS,FSS}) = UnumLarge{ESS,FSS}(x.fsize, x.esize, x.flags, x.fraction, x.exponent)
UnumLarge{ESS,FSS}(x::UnumSmall{ESS,FSS}, flags::UInt16) = UnumLarge{ESS,FSS}(x.fsize, x.esize, flags, x.fraction, x.exponent)

#parameter checking.  The call to this check is autogenerated by the @dev_check macro
function __check_UnumLarge(ESS, FSS, fsize, esize, flags, fraction, exponent)
  __general_unum_check(ESS, FSS, fsize, esize, flags, fraction, exponent)
  (FSS < 7) && throw(ArgumentError("UnumLarge internal class is inappropriate for FSS == $FSS < 7."))
  nothing
end

#override call to allow direct instantiation using the Unum{ESS,FSS} pseudo-constructor.
#because this call function is intended to be used
function call{ESS, FSS}(::Type{Unum{ESS,FSS}}, fsize::UInt16, esize::UInt16, flags::UInt16, fraction::UInt64, exponent::UInt64)
  (FSS > 6) && throw(ArgumentError("FSS = $FSS > 6 requires an UInt64 array"))
  (ESS > 6) && throw(ArgumentError("ESS = $ESS > 6 currently not allowed."))
  UnumSmall{ESS,FSS}(fsize, esize, flags, fraction, exponent)
end

function call{ESS,FSS}(::Type{Unum{ESS, FSS}}, fsize::UInt16, esize::UInt16, flags::UInt16, fraction::ArrayNum{FSS}, exponent::UInt64)
  (ESS > 6) && throw(ArgumentError("ESS = $ESS > 6 currently not allowed."))
  UnumLarge{ESS,FSS}(fsize, esize, flags, fraction, exponent)
end

#for convenience we can also call a big unum with an
function call{ESS,FSS}(::Type{Unum{ESS, FSS}}, fsize::UInt16, esize::UInt16, flags::UInt16, fraction::Array{UInt64, 1}, exponent::UInt64)
  (ESS > 6) && throw(ArgumentError("ESS = $ESS > 6 currently not allowed."))
  (FSS > 11) && throw(ArgumentError("FSS = $FSS > 11 currently not allowed"))
  (FSS < 7) && throw(ArgumentError("FSS = $FSS < 7 should be passed a single Uint64"))
  #calculate the number of cells that fraction will have.
  frac_length = length(fraction)
  need_length = 1 << (FSS - 6)
  (frac_length < need_length) && throw(ArgumentError("insufficient array elements to create unum with desired FSS ($FSS requires $need_length > $frac_length)"))
  #pass this through an intermediate Int64Array number constructor.
  UnumLarge{ESS,FSS}(fsize, esize, flags, ArrayNum{FSS}(fraction), exponent)
end

#the "unum" constructor is a safe constructor that always checks if parameters are
#compliant. note that the first argument to the is pseudo-constructor must be a type value
#that relays the environment signature for the desired unum.

function unum{ESS,FSS}(::Type{Unum{ESS,FSS}}, fsize::UInt16, esize::UInt16, flags::UInt16, fraction, exponent::UInt64)
  #checks to make sure everything is safe.
  __general_unum_check(ESS, FSS, fsize, esize, flags, fraction, exponent)

  #mask out values outside of the flag range.
  flags &= UNUM_FLAG_MASK

  #trim fraction to the length of fsize.  Return the trimmed fsize value and
  #ubit, if appropriate.
  (fraction, fsize, ubit) = __frac_trim(fraction, fsize)
  #apply the ubit change.
  flags |= ubit

  #generate the new Unum.
  Unum{ESS,FSS}(fsize, esize, flags, fraction, exponent)
end

#unum copy pseudo-constructor, safe version
unum{ESS,FSS}(x::Unum{ESS,FSS}) = unum(Unum{ESS,FSS}, x.fsize, x.esize, x.flags, x.fraction, x.exponent)
#and a unum copy that substitutes the flags
unum{ESS,FSS}(x::Unum{ESS,FSS}, subflags::UInt16) = unum(Unum{ESS,FSS}, x.fsize, x.esize, subflags, x.fraction, x.exponent)

#an "easy" constructor which is safe, and takes an unbiased exponent value, and
#a superint value
function unum_easy{ESS,FSS}(::Type{Unum{ESS,FSS}}, flags::UInt16, fraction, exponent::Int)

  exponent < min_exponent(ESS) && throw(ArgumentError("exponent $exponent out-of-bounds for ESS $ESS"))
  exponent > max_exponent(ESS) && throw(ArgumentError("exponent $exponent out-of-bounds for ESS $ESS"))

  #decode the exponent
  (esize, exponent) = encode_exp(exponent)
  #match the length of fraction to FSS, set the ubit if there's trimming that
  #had to be done.
  (fraction, ubit) = __frac_match(fraction, FSS)
  #let's be lazy about the fsize.  The safe unum pseudoconstructor will
  #handle trimming that down.
  fsize = max_fsize(FSS)
  unum(Unum{ESS,FSS}, fsize, esize, flags, fraction, exponent)
end
export unum, unum_easy


#masks for the unum flags variable.
const UNUM_SIGN_MASK = UInt16(0x0002)
const UNUM_UBIT_MASK = UInt16(0x0001)
const UNUM_FLAG_MASK = UInt16(0x0003)
#nb: in the future we may implement g-layer shortcuts:
#in our implementation, these values are sufficient criteria they describe
#are true.  If these flags are not set, further checks must be done.
const UNUM_NAN__MASK = UInt16(0x8000)
const UNUM_ZERO_MASK = UInt16(0x4000)
const UNUM_INF__MASK = UInt16(0x2000)
const UNUM_NINF_MASK = UInt16(0x1000)
const UNUM_SSS__MASK = UInt16(0x0800)
const UNUM_SHORTCUTS = UInt16(0xF800)
