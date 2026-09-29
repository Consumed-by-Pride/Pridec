long sum_to(long n) { long s = 0; for (long i = 1; i <= n; i++) s += i; return s; }
int main(int argc, char**argv) { long n = 1000 + (argc & 1); long r = 0; for (long i = 0; i < 2000000; i++) r += sum_to(n); return (int)r; }
