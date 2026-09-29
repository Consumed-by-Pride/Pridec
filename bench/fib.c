long fib(long n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
int main(void) { long s = 0; for (long i = 0; i < 5; i++) s += fib(30); return (int)s; }
