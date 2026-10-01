; ModuleID = '/home/user/theory-audit/raw-ir/qualifier_read/on/qualifier_read.bc'
source_filename = "Pride"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-p270:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

declare i64 @write(i32, ptr, i64)

; Function Attrs: nosanitize_coverage
declare ptr @malloc(i64) #0

; Function Attrs: nosanitize_coverage
declare void @free(ptr) #1

; Function Attrs: nosanitize_coverage memory(read)
define i64 @add_one(i64 %0) #2 {
entry:
  br label %body

body:                                             ; preds = %entry
  %_t0 = add nsw i64 %0, 1
  ret i64 %_t0
}

; Function Attrs: nosanitize_coverage memory(read)
define i64 @read_first(ptr captures(none) %0) #2 {
entry:
  br label %body

body:                                             ; preds = %entry
  %_t1 = getelementptr i8, ptr %0, i64 0
  %_t2 = load i8, ptr %_t1, align 1
  %_t3 = zext i8 %_t2 to i64
  ret i64 %_t3
}

; Function Attrs: nosanitize_coverage
define i64 @store_first(ptr %0) #3 {
entry:
  %_t0 = alloca i64, align 8
  br label %body

body:                                             ; preds = %entry
  store i64 9, ptr %_t0, align 8
  %_t2 = getelementptr i8, ptr %0, i64 0
  %_t3 = ptrtoint ptr %_t2 to i64
  %_t4 = inttoptr i64 %_t3 to ptr
  %_t5 = load i64, ptr %_t0, align 8
  %_t6 = trunc i64 %_t5 to i8
  store i8 %_t6, ptr %_t4, align 1
  br label %k1

k1:                                               ; preds = %body
  %_t8 = getelementptr i8, ptr %0, i64 0
  %_t9 = load i8, ptr %_t8, align 1
  %_t10 = zext i8 %_t9 to i64
  ret i64 %_t10
}

; Function Attrs: nosanitize_coverage
define i64 @write_via_q(ptr captures(none) %0, ptr %1) #3 {
entry:
  %_t0 = alloca i64, align 8
  br label %body

body:                                             ; preds = %entry
  store i64 11, ptr %_t0, align 8
  %_t2 = getelementptr i8, ptr %1, i64 0
  %_t3 = ptrtoint ptr %_t2 to i64
  %_t4 = inttoptr i64 %_t3 to ptr
  %_t5 = load i64, ptr %_t0, align 8
  %_t6 = trunc i64 %_t5 to i8
  store i8 %_t6, ptr %_t4, align 1
  br label %k2

k2:                                               ; preds = %body
  %_t8 = getelementptr i8, ptr %0, i64 0
  %_t9 = load i8, ptr %_t8, align 1
  %_t10 = zext i8 %_t9 to i64
  ret i64 %_t10
}

; Function Attrs: nosanitize_coverage
define i64 @main(i64 %0) #3 {
entry:
  %_t1 = alloca i64, align 8
  %_t3 = alloca i64, align 8
  %_t4 = alloca i64, align 8
  %_t14 = alloca i64, align 8
  %_t17 = alloca i64, align 8
  %_t19 = alloca i64, align 8
  %_t22 = alloca i64, align 8
  %_t24 = alloca i64, align 8
  %_t28 = alloca i64, align 8
  %_t30 = alloca i64, align 8
  %_t34 = alloca i64, align 8
  %_t38 = alloca i64, align 8
  %_t41 = alloca i64, align 8
  br label %body

body:                                             ; preds = %entry
  %_t0 = call ptr @malloc(i64 8)
  %_t01 = ptrtoint ptr %_t0 to i64
  store i64 %_t01, ptr %_t1, align 8
  %_t2 = load i64, ptr %_t1, align 8
  store i64 %_t2, ptr %_t3, align 8
  store i64 3, ptr %_t4, align 8
  %_t5 = load i64, ptr %_t3, align 8
  %_t6 = inttoptr i64 %_t5 to ptr
  %_t7 = getelementptr i8, ptr %_t6, i64 0
  %_t8 = ptrtoint ptr %_t7 to i64
  %_t9 = inttoptr i64 %_t8 to ptr
  %_t10 = load i64, ptr %_t4, align 8
  %_t11 = trunc i64 %_t10 to i8
  store i8 %_t11, ptr %_t9, align 1
  br label %k3

k3:                                               ; preds = %body
  %_t12 = load i64, ptr %_t3, align 8
  %_t13 = call i64 @read_first(i64 %_t12)
  store i64 %_t13, ptr %_t14, align 8
  %_t15 = load i64, ptr %_t14, align 8
  %_t16 = call i64 @add_one(i64 %_t15)
  store i64 %_t16, ptr %_t17, align 8
  %_t18 = load i64, ptr %_t17, align 8
  store i64 %_t18, ptr %_t19, align 8
  %_t20 = load i64, ptr %_t3, align 8
  %_t21 = call i64 @store_first(i64 %_t20)
  store i64 %_t21, ptr %_t22, align 8
  %_t23 = load i64, ptr %_t22, align 8
  store i64 %_t23, ptr %_t24, align 8
  %_t25 = load i64, ptr %_t3, align 8
  %_t26 = load i64, ptr %_t3, align 8
  %_t27 = call i64 @write_via_q(i64 %_t26, i64 %_t25)
  store i64 %_t27, ptr %_t28, align 8
  %_t29 = load i64, ptr %_t28, align 8
  store i64 %_t29, ptr %_t30, align 8
  %_t31 = load i64, ptr %_t19, align 8
  %_t32 = load i64, ptr %_t24, align 8
  %_t33 = add nsw i64 %_t31, %_t32
  store i64 %_t33, ptr %_t34, align 8
  %_t35 = load i64, ptr %_t34, align 8
  %_t36 = load i64, ptr %_t30, align 8
  %_t37 = add nsw i64 %_t35, %_t36
  store i64 %_t37, ptr %_t38, align 8
  %_t39 = load i64, ptr %_t3, align 8
  %_t40 = call i64 @read_first(i64 %_t39)
  store i64 %_t40, ptr %_t41, align 8
  %_t42 = load i64, ptr %_t38, align 8
  %_t43 = load i64, ptr %_t41, align 8
  %_t44 = add nsw i64 %_t42, %_t43
  ret i64 %_t44
}

attributes #0 = { nosanitize_coverage "allockind"="alloc,uninitialized" }
attributes #1 = { nosanitize_coverage "allockind"="free" }
attributes #2 = { nosanitize_coverage memory(read) }
attributes #3 = { nosanitize_coverage }
