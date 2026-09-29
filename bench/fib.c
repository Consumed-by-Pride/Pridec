long fib(long n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
int main(int argc, char**argv) { long n = 38 + (argc & 1); long s = 0; for (long i = 0; i < 5; i++) s += fib(n); return (int)s; }
