#unum-oddsandends.jl
#mathematical odds and ends

################################################################################

doc"""
  `Unums.frac_val(::UInt64)`
  `Unums.frac_val(::ArrayNum)`
  returns the integral value for a number used as a fraction.
"""
frac_val(x::UInt64) = x
function frac_val{FSS}(v::ArrayNum{FSS})
  (typeof(v) == UInt64) && return big(v)
  sum = big(0)
  for i = 1:length(v.a)
    sum += big(v.a[i]) * (big(1) << ((i - 1) * 64))
  end
  sum
end

doc"""`Unums.calculate(x::Unum)` returns a bigfloat equivalent of the unum.  NB:
currently doesn't work so well for FSS > 9"""
@universal function calculate(x::Unum)
  sign = (x.flags & UNUM_SIGN_MASK != 0) ? -1 : 1
  #the sub`normal case
  if (x.exponent == 0)
    2.0^(decode_exp(x) + 1) * sign * (frac_val(x.fraction)) / 2.0^(64 * length(x.fraction))
  else #the normalcase
    2.0^(decode_exp(x)) * sign * (1 + frac_val(x.fraction) / 2.0^(64 * length(x.fraction)))
  end
end
export calculate

################################################################################

doc"""
  `additiveinverse!` creates the additive inverse value of a unum, by flipping
  the sign.  This can be better than the `-` operator because it doesn't copy
  the unum.  A reference to the unum is returned.
"""
@universal additiveinverse!(x::Unum) = (x.flags $= UNUM_SIGN_MASK; return x)
export additiveinverse!

doc"""
  `coerce_sign!(a::Unum, b)` maps the sign bit from b onto a.  b can either be a
  UInt16 or a Unum.
"""
@universal coerce_sign!(a::Unum, b::Unum) = coerce_sign!(a, b.flags)
@universal coerce_sign!(a::Unum, sgn::UInt16) = (a.flags = (a.flags & ~UNUM_SIGN_MASK) | sgn; return a)

doc"""
  `abs!(::Unum)` forces the value of the unum to be positive.  Returns the
  unum for chaining purposes.
"""
@universal abs!(x::Unum) = ((x.flags &= ~UNUM_SIGN_MASK); return x)
export abs!

@universal function Base.copy!(dest::Unum, src::Unum)
  dest.fsize = src.fsize
  dest.esize = src.esize
  dest.flags = src.flags & UNUM_FLAG_MASK
  dest.exponent = src.exponent

  (FSS < 7) ? (dest.fraction = src.fraction) : (copy!(dest.fraction, src.fraction))

  return dest  #for chaining purposes
end

#=
doc"""
  Unums.match_fsize!{ESS,FSS} takes the location of fsize and moves it over to dest.

  The exponent on src should less than or equal to the exponent on dest.
"""
function match_fsize!{ESS,FSS}(src::Unum{ESS,FSS}, dest::Unum{ESS,FSS})
  src_exp::Int64 = decode_exp(src)
  dest_exp::Int64 = decode_exp(dest)
  dest.fsize = UInt16(min(src.fsize + dest_exp - src_exp, max_fsize(FSS)))
end
=#
#=
#note the difference between "more/less", and "next/prev" - next/prev refers
#to position along the number line, "more/less" refers to magnitude along the
#number line.  NB:  __bigger_exact and __smaller_exact do *not* perform checks
#on the properties of their passed values so should be used with caution.

function __outward_exact{ESS,FSS}(a::Unum{ESS,FSS})
  #set the location of the added bit:  remember that fsize is the actual length - 1
  location = (is_ulp(a)) ? a.fsize + 1 : max_fsize(FSS)
  #generate a new superint that represents what we're going to add in.
  delta = __bit_from_top(location, length(a.fraction))
  #add the delta in, making it a
  (carry, fraction) = __carried_add(z64, a.fraction, delta)

  #check the two cases.
  if (carry != 0)
    (esize, exponent) = encode_exp(decode_exp(a) + 1)
    fraction = lsh(fraction, o16)
  else
    esize = a.esize
    exponent = a.exponent
  end
  #recalculate fsize, since this is exact, we can deal with ULPs as needed.
  fsize::UInt16 = __minimum_data_width(fraction)

  Unum{ESS,FSS}(fsize, esize, a.flags & UNUM_SIGN_MASK, fraction, exponent)
end
=#

doc"""
  `Unums.normalize!(::Unum)` takes a unum that is purportedly subnormal form and
  normalizes it.  This entails shifting just past the top bit.  this function
  returns the number of places shifted.

  This function should not be run on a fraction that is all zero, nor on a
  function which is not subnormal.
"""
@universal function normalize!(x::Unum)
  leftshift = clz(x.fraction) + o16
  frac_lsh!(x, leftshift)
  x.fsize -= leftshift
  return leftshift
end

doc"""
  `Unums.resolve_degenerates!(::Unum)` checks for degeneracy in unum values,
  and resolves to "canonical" form - which means all nonzero subnormals are
  converted to normal form if possible, and exact zeros are the smallest zero.
  fsize is maximally trimmed for exact values.
"""
@universal function resolve_degenerates!(x::Unum)
  (x.exponent != 0) && return x   #kick out if our exponent is not zero.
  (x.esize == max_esize(ESS)) && return x #kick out if we're not a strange subnormal.
  if is_all_zero(x.fraction)
    is_exact(x) && return zero(typeof(x))
    return x #if we're actually zero or a zero+ulp subnormal we can't shift.
  end

  true_exponent = decode_exp(x)
  #now, count leading zeros, be prepared to shift left.
  leftshift = normalize!(x)
  true_exponent -= leftshift - o16
  (x.esize, x.exponent) = encode_exp(true_exponent)
  exact_trim!(x)

  return x
end

################################################################################
## variadic macros that trigger exactitude checking.

if options[:devmode]
  macro ensure_exact(x)
    esc(options[:devmode] ? :(is_exact($x) || throw(ArgumentError("passed parameter must be exact"))) : :())
  end
else
  macro ensure_exact(x); :(); end
end

if options[:devmode]
  macro ensure_ulp(x)
    esc(options[:devmode] ? :(is_ulp($x) || throw(ArgumentError("passed parameter must be an ulp"))) : :())
  end
else
  macro ensure_ulp(x); :(); end
end

################################################################################
## sophisticated exactitude functions.

doc"""
  `Unums.outward_ulp!(::Unum)` returns the smallest-width ulp immediately above the
  current (exact) unum.
"""
@universal function outward_ulp!(x::Unum)
  @ensure_exact(x)

  resolve_degenerates!(x)

  x.fsize = max_fsize(FSS)
  make_ulp!(x)
end
@universal outward_ulp(x::Unum) = outward_ulp!(copy(x))

doc"""
  `Unums.inward_ulp!(::Unum)` returns the smallest-width ulp immediately below the
  current unum.
"""
@universal function inward_ulp!(x::Unum)
  @ensure_exact(x)
  resolve_degenerates!(x)
  make_ulp!(x)

  borrowed = frac_sub_ubit!(x, max_fsize(FSS))

  #if we borrowed, then fraction must have been zero.
  if borrowed
    #there is no ulp inward of x.  Consider replacing this with "Throw an error"
    (x.exponent == 0) && return nan!(x)
    _xexp = decode_exp(x)
    (_xexp == min_exponent(ESS)) && (x.exponent = 0; return x)
    (x.esize, x.exponent) = encode_exp(_xexp - 1)
  end
  x.fsize = max_fsize(FSS)

  return x
end
@universal inward_ulp(x::Unum) = inward_ulp!(copy(x))

doc"""
"""
@universal function outward_exact!(x::Unum)
  @ensure_ulp(x)
  resolve_degenerates!(x)
  carry = frac_add_ubit!(x, x.fsize)
  if carry
    if (is_subnormal(x))
      (x.exponent = o64)
    else
      exp = decode_exp(x) + 1
      if exp > max_exponent(ESS)
        inf!(x)
      else
        (x.esize, x.exponent) = encode_exp(exp)
      end
    end
  end
  exact_trim!(make_exact!(x))
end
@universal outward_exact(x::Unum) = outward_exact!(copy(x))

@universal function inward_exact!(x::Unum)
  @ensure_ulp(x)
  make_exact!(x)
end
@universal inward_exact(x::Unum) = inward_exact!(copy(x))

################################################################################
## recast as upper and lower versions.

@universal upper_exact!(x::Unum) = is_positive(x) ? outward_exact!(x) : inward_exact!(x)
@universal lower_exact!(x::Unum) = is_positive(x) ? inward_exact!(x) : outward_exact!(x)
@universal upper_ulp!(x::Unum) = is_positive(x) ? outward_ulp!(x) : inward_ulp!(x)
@universal lower_ulp!(x::Unum) = is_positive(x) ? inward_ulp!(x) : outward_ulp!(x)

@universal upper_exact(x::Unum) = upper_exact!(copy(x))
@universal lower_exact(x::Unum) = lower_exact!(copy(x))
@universal upper_ulp(x::Unum) = upper_ulp!(copy(x))
@universal lower_ulp(x::Unum) = lower_ulp!(copy(x))

################################################################################

@universal function next_unum!(x::Unum)
  @ensure_exact(x)
  resolve_degenerates!(x)
  carried = frac_add_ubit!(x, max_fsize(FSS))
  if carried
    exponent = decode_exp(x)
    (exponent > max_exponent(ESS)) && return inf(x)
    (x.esize, x.exponent) = encode_exp(exponent + 1)
  end
  exact_trim!(x)
  return x
end

@universal next_unum(x::Unum) = next_unum!(copy(x))
################################################################################
## dumb exactitude functions.

doc"""`Unums.make_exact(::Unum)` forces the ubit of a unum to be 0."""
@universal make_exact!(x::Unum) = (x.flags &= ~UNUM_UBIT_MASK; x)

doc"""`Unums.make_ulp(::Unum)` forces the ubit of a unum to be 1."""
@universal make_ulp!(x::Unum) = (x.flags |= UNUM_UBIT_MASK; x)

################################################################################
## carry resolution

doc"""
  `Unums.resolve_carry!(carry::UInt64, ::Unum, exponent::Int64)` resolves a
  carry (invisible bit) value that may exceed one after calculation events.
  You should pass this function an exponent value that will be returned,
  appropriately modified.
"""
@universal function resolve_carry!(carry::UInt64, x::Unum, exponent::Int64)
  leftzeroes = clz(carry)
  if (leftzeroes < 0x003F) #less than 63 zeroes
    shift = 0x003F - leftzeroes
    rsh_and_set_ubit!(x, shift)
    #now copy the bits over from the carried segment.
    frac_copy_top!(x, (((o64 << shift) - o64) & carry) << (leftzeroes + o16))
    exponent += shift
  end
  (exponent > max_exponent(ESS)) && mmr!(x)  #set it to mmr, if the exponent is too large.
  (x.esize, x.exponent) = encode_exp(exponent)
end
