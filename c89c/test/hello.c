/* hello.c — tiny C89 smoke test */
int putchar(int c);
int exit(int code);

int add(int a, int b) {
    return a + b;
}

int main() {
    int x;
    x = add(21, 21);
    return x;
}
