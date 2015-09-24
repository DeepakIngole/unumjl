#unum-division.jl - currently uses the goldschmidt method, but will also
#implement other division algorithms.

function /{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS})
  #some basic test cases.

  #check NaNs
  (isnan(a) || isnan(b)) && return nan(Unum{ESS,FSS})

  #division by zero is ALWAYS a NaN in unums.
  is_zero(b) && return nan(Unum{ESS,FSS})
  #multiplication by zero is always zero, except 0/0 which is covered above.
  is_zero(a) && return zero(Unum{ESS,FSS})

  #division by inf will almost always be zero.
  if is_inf(b)
    #unless the numerator is also infinite
    is_inf(a) && return nan(Unum{ESS,FSS})
    return zero(Unum{ESS,FSS})
  end

  div_sign::Uint16 = ((a.flags & UNUM_SIGN_MASK) $ (b.flags & UNUM_SIGN_MASK))
  #division from inf is always inf, with a possible sign change
  if is_inf(a)
    return inf(Unum{ESS,FSS}, div_sign)
  end

  is_unit(b) && return unum_unsafe(a, a.flags $ b.flags)

  if (is_ulp(a) || is_ulp(b))
    __div_ulp(a, b, div_sign)
  else
    __div_exact(a, b)
  end
end

function __div_ulp{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS}, div_sign::Uint16)
  #dividing by smaller than small subnormal will yield the entire number line.
  if is_sss(b)
    innerbound = _div_exact(a, small_exact(Unum{ESS,FSS}, b.flags & UNUM_SIGN_MASK))
    (div_sign != 0) && return ubound_unsafe(neg_mmr(Unum{ESS,FSS}), innerbound)
    return ubound_resolve(ubound_unsafe(innerbound, pos_mmr(Unum{ESS,FSS})))
  end
  #should have a similar process for mmr.
  if is_mmr(b)
    outerbound = __div_exact(b, big_exact(Unum{ESS,FSS}, b.flags & UNUM_SIGN_MASK))
    (div_sign != 0) && return ubound_unsafe(outerbound, neg_sss(Unum{ESS,FSS}))
    return ubound_resolve(ubound_unsafe(pos_sss(Unum{ESS,FSS}), outerbound))
  end
  #dividing from a smaller than small subnormal
  if is_sss(a)
    outerbound = __div_exact(small_exact(Unum{ESS,FSS}, a.flags & UNUM_SIGN_MASK), b)
    (div_sign != 0) && return ubound_unsafe(outerbound, neg_sss(Unum{ESS,FSS}))
    return ubound_resolve(ubound_unsafe(pos_sss(Unum{ESS,FSS}), outerbound))
  end
  #and a similar process for mmr
  if is_mmr(a)
    innerbound = __div_exact(big_exact(Unum{ESS,FSS}, a.flags & UNUM_SIGN_MASK), a)
    (div_sign != 0) && return ubound_unsafe(neg_mmr(Unum{ESS,FSS}), innerbound)
    return ubound_resolve(ubound_unsafe(innerbound, pos_mmr(Unum{ESS,FSS})))
  end
  #assign "exact" and "bound" a's
  (exact_a, bound_a) = is_ulp(a) ? (unum_unsafe(a, a.flags & ~UNUM_UBIT_MASK), __outward_exact(a)) : (a, a)
  (exact_b, bound_b) = is_ulp(b) ? (unum_unsafe(b, b.flags & ~UNUM_UBIT_MASK), __outward_exact(b)) : (b, b)
  #find the high and low bounds.  Pass this to a subsidiary function
  far_result  = __mult_exact(bound_a, exact_b)
  near_result = __mult_exact(exact_a, bound_b)
  if ((a.flags & UNUM_SIGN_MASK) != (b.flags & UNUM_SIGN_MASK))
    ubound_resolve(open_ubound(far_result, near_result))
  else
    ubound_resolve(open_ubound(near_result, far_result))
  end
end

#sfma is "simple fused multiply add".  Following assumptions hold:
#first, number has the value 1.XXXXXXX, factor is
function __sfma(carry, number, factor)
  (fracprod, _) = Unums.__chunk_mult(number, factor)
  (_carry, fracprod) = Unums.__carried_add(carry, number, fracprod)
  ((carry & 0x1) != 0) && ((_carry, fracprod) = Unums.__carried_add(_carry, factor, fracprod))
  ((carry & 0x2) != 0) && ((_carry, fracprod) = Unums.__carried_add(_carry, lsh(factor, 1), fracprod))
  (_carry, fracprod)
end

#performs a simple multiply, Assumes that number 1 has a hidden bit of exactly one
#and number 2 has a hidden bit of exactly zero
#(1 + a)(0 + b) = b + ab
function __smult(a::SuperInt, b::SuperInt)
  (fraction, _) = Unums.__chunk_mult(a, b)
  carry = one(Uint64)

  #only perform the respective adds if the *opposing* thing is not subnormal.
  ((carry, fraction) = Unums.__carried_add(carry, fraction, b))

  #carry may be as high as three!  So we must shift as necessary.
  (fraction, shift, is_ubit) = Unums.__shift_after_add(carry, fraction, _)
  lsh(fraction, 1)
end

const __EXACT_INDEX_TABLE = [0, 0, 0, 0, 0, 0, 2, 3, 5, 9, 17, 33, 65]
const __HALFMASK_TABLE = [0xEFFF_FFFF_FFFF_FFFF, 0xCFFF_FFFF_FFFF_FFFF, 0x0FFF_FFFF_FFFF_FFFF, 0x00FF_FFFF_FFFF_FFFF, 0x0000_FFFF_FFFF_FFFF, 0x0000_0000_FFFF_FFFF]

function __check_exact(a::SuperInt, b::SuperInt, fss)
  if (fss == 0)
    return a == b
  elseif (fss < 6)
    return ((a & __HALFMASK_TABLE[fss]) == 0) && ((b & __HALFMASK_TABLE[fss]) == 0)
  elseif (fss == 6)
    return (a[1] == 0) && (b[1] == 0) && (a[2] & __HALFMASK_TABLE[6] == 0) && (b[2] & __HALFMASK_TABLE[6] == 0)
  elseif (fss > 6)
    #possibly, a is all zero.
    for idx = 1:__EXACT_INDEX_TABLE[fss]
      ((a[idx] != 0) || (b[idx] != 0)) && return false
    end
    return true
  end
end

#helper function all ones.  decides if fraction has enough ones.
function allones(fss)
  (fss < 6) && return ((1 << (1 << fss)) - 1) << (64 - (1 << fss))
  (fss == 6) && return f64
  [f64 for i = 1:__frac_cells(fss)]
end

function __div_exact{ESS,FSS}(a::Unum{ESS,FSS}, b::Unum{ESS,FSS})
  div_length::Uint16 = length(a.fraction) + ((FSS >= 6) ? 1 : 0)
  #figure out the sign.
  sign::Uint16 = (a.flags & UNUM_SIGN_MASK) $ (b.flags & UNUM_SIGN_MASK)

  #calculate the exponent.
  exp_f::Int64 = decode_exp(a) - decode_exp(b) + (issubnormal(a) ? 1 : 0) - (issubnormal(b) ? 1 : 0)

  #first bring the numerator into coherence.
  numerator::SuperInt = (FSS >= 6) ? [z64, a.fraction] : a.fraction

  #save the old numerator.
  if (issubnormal(a))
    shift::Uint64 = clz(numerator) + 1
    numerator = lsh(numerator, shift)
    exp_f -= shift
  end
  _numerator = __copy_superint(numerator)
  carry::Uint64 = 1

  #next bring the denominator into coherence.
  denominator::SuperInt = (FSS >= 6) ? [z64, b.fraction] : b.fraction
  if issubnormal(b)
    shift = clz(denominator)
    denominator = lsh(denominator, shift)
    exp_f += shift
  else
    #shift the phantom one over.
    denominator = rsh(denominator, 1) | fillbits(-1, div_length)
    exp_f -= 1
  end
  #save the old denominator.
  _denominator = __copy_superint(denominator)


  #bail out if the exponent is too big or too small.
  (exp_f > max_exponent(ESS)) && return (sign != 0) ? neg_mmr(Unum{ESS,FSS}) : neg_mmr(Unum{ESS,FSS})
  (exp_f < min_exponent(ESS) - max_fsize(FSS) - 2) && return (sign != 0) ? neg_sss(Unum{ESS,FSS}) : neg_sss(Unum{ESS,FSS})

  #figure out the mask we need.
  if (FSS <= 5)
    division_mask = fillbits(-(max_fsize(FSS) + 4), o16)
  else
    division_mask = [0xF000_0000_0000_0000, [f64 for idx=1:__frac_cells(FSS)]]
  end

  #iteratively improve x.
  for (idx = 1:32)  #we will almost certainly not get to 32 iterations.
    (_, factor) = __carried_diff(o64, ((FSS >= 6) ? zeros(Uint64, div_length) : z64), denominator)
    (carry, numerator) = __sfma(carry, numerator, factor)
    (_, denominator) = __sfma(z64, denominator, factor)

    #println("$idx:",superbits(numerator))
    #println("$idx:",superbits(denominator))

    allzeros(~denominator & division_mask) && break
    #note that we could mask out denominator and numerator with "division_mask"
    #but we're not going to bother.
  end

  #append the carry, shift exponent as necessary.
  if carry > 1
    numerator = rsh(numerator, 1) | (carry & 0x1 << 63)
    carry = 1
    exp_f += 1
  end

  #based on the correct exponent, decide if we need to output a generic.
  (exp_f > max_exponent(ESS)) && return (sign != 0) ? neg_mmr(Unum{ESS,FSS}) : neg_mmr(Unum{ESS,FSS})
  (exp_f < min_exponent(ESS) - max_fsize(FSS)) && return (sign != 0) ? neg_sss(Unum{ESS,FSS}) : neg_sss(Unum{ESS,FSS})

  numerator &= division_mask
  is_ulp::Uint16 = UNUM_UBIT_MASK
  fsize::Uint16 = max_fsize(FSS)

  frac_delta::SuperInt = (FSS < 6) ? (t64 >> max_fsize(FSS)) : [z64, o64, [z64 for idx=1:(__frac_cells(FSS) - 1)]]

  frac_mask::SuperInt = (FSS < 6) ? (fillbits(int64(-(max_fsize(FSS) + 1)), o16)) : [z64, [f64 for idx=1:__frac_cells(FSS)]]
  #check our math to assign ULPs

  reseq = __smult((numerator & frac_mask), _denominator)
  (carry2, np1) = __carried_add(o64, numerator & frac_mask, frac_delta)
  resph = __smult(np1, _denominator)

  if _numerator < reseq
    (carry, numerator) = __carried_diff(carry, numerator, frac_delta)
  #if being exact is possible, run a check exact.
  elseif _numerator == reseq
    __check_exact(numerator, _denominator, FSS) && (is_ulp = 0)
  elseif _numerator == resph
    __check_exact(np1, _denominator, FSS) && (is_ulp = 0)
    (carry, numerator) = (carry2, np1)
  elseif _numerator > resph
    (carry, numerator) = (carry2, np1)
  end

  (carry < 1) && (numerator = rsh(numerator, 1))
  (carry > 1) && (numerator = lsh(numerator, 1))

  (exp_f < min_exponent(ESS)) && ((exp_f, numerator) = fixsn(ESS, FSS, exp_f, numerator))

  if (FSS < 6)
    fraction = numerator & frac_mask
  elseif (FSS == 6)
    fraction = numerator[2]
  else
    fraction = numerator[2:__frac_cells(FSS)]
  end

  (is_ulp & UNUM_UBIT_MASK == 0) && (fsize = __fsize_of_exact(fraction))

  (esize, exponent) = encode_exp(exp_f)

  Unum{ESS,FSS}(fsize, esize, sign | is_ulp, fraction, exponent)
end
