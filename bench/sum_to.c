long sum_to(long n) { long s = 0; for (long i = 1; i <= n; i++) s += i; return s; }
int main(void) { long r = 0; for (long i = 0; i < 2000000; i++) r += sum_to(1000); return (int)r; }
