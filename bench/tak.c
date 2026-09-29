long tak(long x, long y, long z) { if (y < x) return tak(tak(x-1,y,z), tak(y-1,z,x), tak(z-1,x,y)); return z; }
int main(int argc, char**argv) { long x = 24 + (argc & 1); long s = 0; for (long i = 0; i < 20; i++) s += tak(x,16,8); return (int)s; }
