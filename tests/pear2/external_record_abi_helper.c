#include <stdint.h>

typedef struct {
    int64_t left;
    int64_t right;
} Pair;

Pair pear2_make_pair(int64_t left, int64_t right) {
    Pair value = { left, right };
    return value;
}

Pair pear2_tuple_make(int64_t left, int64_t right) {
    Pair value = { left, right };
    return value;
}

int64_t pear2_pair_sum(Pair value) {
    return value.left + value.right;
}

// AIR tuple(i64, i64) is represented as a literal LLVM struct and uses the
// matching two-register C aggregate ABI on the supported x86-64 target.
int64_t pear2_tuple_sum(Pair value) {
    return value.left + value.right;
}
