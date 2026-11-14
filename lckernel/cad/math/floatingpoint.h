#pragma once

#include <cmath>
#include <limits>

namespace lc {
namespace maths {

constexpr unsigned int DefaultComparisonUlps = 4;

enum class FloatingOrder { Less, Equivalent, Greater, Unordered };
enum class FloatingSign { Negative, Zero, Positive, NonFinite };

/** Compare doubles within maxUlps representable steps of one another.
 * NaNs are unordered; infinities compare equal only to the same infinity.
 * Signed zeros are equivalent. Equivalence is not transitive and must not
 * be used as an ordering predicate for associative containers or sorting.
 * The cost is linear in maxUlps, which should normally be a small number.
 */
inline FloatingOrder compareWithinUlps(double value, double boundary,
                                       unsigned int maxUlps = DefaultComparisonUlps) noexcept {
    if (std::isnan(value) || std::isnan(boundary)) {
        return FloatingOrder::Unordered;
    }
    if (std::isinf(value) || std::isinf(boundary)) {
        if (std::isinf(value) && std::isinf(boundary)) {
            if (std::signbit(value) == std::signbit(boundary)) {
                return FloatingOrder::Equivalent;
            }
            return std::signbit(value) ? FloatingOrder::Less : FloatingOrder::Greater;
        }
        if (std::isinf(value)) {
            return std::signbit(value) ? FloatingOrder::Less : FloatingOrder::Greater;
        }
        return std::signbit(boundary) ? FloatingOrder::Greater : FloatingOrder::Less;
    }

    double lower = boundary;
    double upper = boundary;
    const double infinity = std::numeric_limits<double>::infinity();
    for (unsigned int ulp = 0; ulp < maxUlps; ++ulp) {
        lower = std::nextafter(lower, -infinity);
        upper = std::nextafter(upper, infinity);
    }
    if (value < lower) return FloatingOrder::Less;
    if (value > upper) return FloatingOrder::Greater;
    return FloatingOrder::Equivalent;
}

/** Classify finite signs, treating values within maxUlps of zero as zero. */
inline FloatingSign signWithinUlpsOfZero(double value,
                                         unsigned int maxUlps = DefaultComparisonUlps) noexcept {
    if (!std::isfinite(value)) return FloatingSign::NonFinite;
    if (compareWithinUlps(value, 0., maxUlps) == FloatingOrder::Equivalent) {
        return FloatingSign::Zero;
    }
    return std::signbit(value) ? FloatingSign::Negative : FloatingSign::Positive;
}

} // namespace maths
} // namespace lc
