#unum-multiplication.jl
#does multiplication for unums.

doc"""
  `Unums.frac_mul!(carry, ::Unum, fraction)`
  multiplies fraction into the the fraction value of unum.
"""
function frac_mul!{ESS,FSS}(a::UnumSmall{ESS,FSS}, multiplier::UInt64)
  (carry, a.fraction, ubit) = i64mul(a.fraction, multiplier, Val{FSS})
  a.flags |= ubit
  return carry + o64
end

frac_mul!{ESS,FSS}(a::UnumLarge{ESS,FSS}, multiplier::ArrayNum{FSS}) = frac_mul!(a, multiplier, Val{__cell_length(FSS)}, Val{true})
function frac_mul!{ESS,FSS, cells, addin}(a::UnumLarge{ESS,FSS}, multiplier::ArrayNum{FSS}, ::Type{Val{cells}}, ::Type{Val{addin}})
  (carry, ubit) = i64mul!(a.fraction, multiplier, Val{cells}, Val{addin})
  a.flags |= ubit
  return carry + o64
end

doc"""
  `Unums.mul(::Unum, ::Unum)` outputs a Unum OR Ubound corresponding to the product
  of two unums.  This is bound to the (\*) operation if options[:usegnum] is not
  set.  Note that in the case of degenerate unums, mul may change the bit values
  of the individual unums, but the values will not be altered.
"""
@universal function mul(a::Unum, b::Unum)
  #some basic checks out of the gate.
  (is_nan(a) || is_nan(b)) && return nan(U)
  is_zero(a) && return is_inf(b) ? nan(U) : zero(b)
  is_zero(b) && return is_inf(a) ? nan(U) : zero(a)

  result_sign = (a.flags $ b.flags) & UNUM_SIGN_MASK

  is_unit(a) && return coerce_sign!(copy(b), result_sign)
  is_unit(b) && return coerce_sign!(copy(a), result_sign)

  is_inf(a) && return inf(U, result_sign)
  is_inf(b) && return inf(U, result_sign)

  #resolve degenerate conditions in both A and B before calculating the exponents.
  resolve_degenerates!(a)
  resolve_degenerates!(b)

  if (is_exact(a) && is_exact(b))
    mul_exact(a, b, result_sign)
  else
    mul_inexact(a, b, result_sign)
  end
end

@universal function mul_exact(a::Unum, b::Unum, result_sign::UInt16)
  #first, calculate the exponents.
  _asubnormal = is_subnormal(a)
  _bsubnormal = is_subnormal(b)

  _aexp = decode_exp(a)
  _bexp = decode_exp(b)

  #solve the exponent.
  exponent = _aexp + _bexp

  (exponent > max_exponent(ESS)) && return mmr(U, result_sign)
  (exponent < min_exponent(ESS,FSS) && return sss(U, result_sign))

  exponent += _asubnormal * 1 + _bsubnormal * 1

  #TODO: convert this into "supranormal form"

  #solve the fractional product.
  if _asubnormal
    result = copy(a)
    multiplicand = b
    is_ulp(b) && make_ulp!(result)

    exponent -= normalize!(result)

    #this code is only necessary when ESS == 0, because you can have subnormal 1's
    #which don't exponent-degrade.
    if (ESS == 0)
      if _bsubnormal
        multiplicand = copy(b)
        exponent -= normalize!(multiplicand)
      end
    end
  else
    result = copy(b)
    multiplicand = a
    is_ulp(a) && make_ulp!(result)

    if _bsubnormal
      #normalize b (regardless of exponent)
      exponent -= normalize!(result)
    end
  end

  #check for a really small exponent (again!)
  (exponent < min_exponent(ESS,FSS) && return sss(U, result_sign))

  carry = frac_mul!(result, multiplicand.fraction)

  if (FSS < 6)
    result.fraction &= mask_top(FSS)
  end

  resolve_carry!(carry, result, exponent)

  if (exponent < min_exponent(ESS))
    #in the case that we need to make this subnormal.
    right_shift = to16(min_exponent(ESS) - exponent)
    frac_rsh_underflow_check!(result, right_shift)
    frac_set_bit!(result, right_shift)
    result.esize = max_esize(ESS)
    result.exponent = z64
  end

  is_exact(result) && exact_trim!(result)
  result.fsize = min(result.fsize, max_fsize(FSS))

  return coerce_sign!(result, result_sign)
end

@universal function mul_inexact(a::Unum, b::Unum, result_sign::UInt16)
  is_mmr(a) && (return mmr_mult(b, result_sign))
  is_mmr(b) && (return mmr_mult(a, result_sign))

  is_sss(a) && (return sss_mult(b, result_sign))
  is_sss(b) && (return sss_mult(a, result_sign))

  inner_result = mul_exact(a, b, result_sign)

  make_ulp!(inner_result)
  result_exponent = decode_exp(inner_result) + is_subnormal(inner_result) * 1

  if is_exact(a)
    outer_result = sum_exact(inner_result, a, result_exponent, result_exponent - b.fsize - 1)
  elseif is_exact(b)
    outer_result = sum_exact(inner_result, b, result_exponent, result_exponent - a.fsize - 1)
  else
    (_precise, _fuzzy) = (a.fsize < b.fsize) ? (b , a) : (a, b)

    outer_result = copy(_precise)
    shift = _precise.fsize - _fuzzy.fsize

    frac_rsh!(outer_result, shift)

    carry = z64
    (issubnormal(_precise)) || ((shift == z16) ? (carry = o64) : (frac_set_bit!(outer_result, shift)))
    #add the two fractionals parts together, and set the carry.
    carry = frac_add!(carry, outer_result, _fuzzy.fraction)
    frac_rsh!(outer_result, _fuzzy.fsize)

    carry2 = z64
    ((carry & o64) != z64) && ((shift == z16) ? (carry2 = o64) : frac_set_bit!(outer_result, shift))
    ((carry & 0x0000_0000_0000_0002) != z64) && ((shift == o16) ? (carry2 = o64) : frac_set_bit!(outer_result, (shift - o16)))
    carry2 = frac_add!(carry2, outer_result, inner_result.fraction)

    resolve_carry!(carry2, outer_result, result_exponent)

    #if we wound up still subnormal, then re-subnormalize the exponent. (exp - 1)
    outer_result.exponent &= f64 * (carry2 != 0)

    #check to see if we're getting too big.
    (outer_result.exponent > max_biased_exponent(ESS)) && mmr!(outer_result, result_sign)
    #check to make sure we haven't done the inf hack, where the result exactly
    #equals inf.
    __is_nan_or_inf(outer_result) && mmr!(outer_result, result_sign)
  end

  return (result_sign == z16) ? resolve_as_utype!(inner_result, outer_result) : resolve_as_utype!(outer_result, inner_result)
end


@universal function mmr_mult(a::Unum, result_sign::UInt16)
  if mag_greater_than_one(a)
    return mmr(U, result_sign)
  else
    is_sss(a) && return (result_sign == 0) ? B(sss(U), mmr(U)) : B(neg_mmr(U), neg_sss(U))
    return nan(U)
  end
end

@universal function sss_mult(a::Unum, result_sign::UInt16)
  if mag_greater_than_one(a)
    temp1 = small_exact(U, result_sign)
    temp2 = is_exact(a) ? a : outer_exact(a)

    outer_value = mul_exact(temp1, temp2, result_sign)

    is_exact(outer_value) && inner_ulp!(outer_value)

    (result_sign == z16) ? resolve_as_utype!(sss(U, result_sign), outer_value) : resolve_as_utype!(outer_value, sss(U, result_sign))
  else
    return sss(U, result_sign)
  end
end

#import the Base add operation and bind it to the add and add! functions
import Base.*
@bind_operation(*, mul)
