; ModuleID = '/home/user/theory-audit/raw-ir/dense_dispatch/on/dense_dispatch.bc'
source_filename = "Pride"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-p270:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

declare i64 @write(i32, ptr, i64)

; Function Attrs: nosanitize_coverage
declare ptr @malloc(i64) #0

; Function Attrs: nosanitize_coverage
declare void @free(ptr) #1

; Function Attrs: nosanitize_coverage memory(read)
define i64 @choose(i64 %0) #2 {
entry:
  br label %body

body:                                             ; preds = %entry
  switch i64 %0, label %switch.default4 [
    i64 0, label %switch.case0
    i64 1, label %switch.case1
    i64 2, label %switch.case2
    i64 3, label %switch.case3
  ]

switch.case0:                                     ; preds = %body
  ret i64 10

switch.case1:                                     ; preds = %body
  ret i64 21

switch.case2:                                     ; preds = %body
  ret i64 32

switch.case3:                                     ; preds = %body
  ret i64 43

switch.default4:                                  ; preds = %body
  ret i64 99
}

; Function Attrs: nosanitize_coverage memory(read)
define i64 @choose_char(i64 %0) #2 {
entry:
  br label %body

body:                                             ; preds = %entry
  switch i64 %0, label %switch.default4 [
    i64 97, label %switch.case0
    i64 98, label %switch.case1
    i64 99, label %switch.case2
    i64 100, label %switch.case3
  ]

switch.case0:                                     ; preds = %body
  ret i64 50

switch.case1:                                     ; preds = %body
  ret i64 51

switch.case2:                                     ; preds = %body
  ret i64 33

switch.case3:                                     ; preds = %body
  ret i64 53

switch.default4:                                  ; preds = %body
  ret i64 80
}

; Function Attrs: nosanitize_coverage memory(read)
define i64 @choose_clause(i64 %0) #2 {
entry:
  br label %body

body:                                             ; preds = %entry
  switch i64 %0, label %switch.default4 [
    i64 0, label %switch.case0
    i64 1, label %switch.case1
    i64 2, label %switch.case2
    i64 3, label %switch.case3
  ]

switch.case0:                                     ; preds = %body
  ret i64 15

switch.case1:                                     ; preds = %body
  ret i64 16

switch.case2:                                     ; preds = %body
  ret i64 17

switch.case3:                                     ; preds = %body
  ret i64 18

switch.default4:                                  ; preds = %body
  %_t0 = add nsw i64 %0, 17
  ret i64 %_t0
}

; Function Attrs: nosanitize_coverage memory(read)
define i64 @main(i64 %0) #2 {
entry:
  %_t1 = alloca i64, align 8
  %_t3 = alloca i64, align 8
  %_t7 = alloca i64, align 8
  %_t9 = alloca i64, align 8
  %_t13 = alloca i64, align 8
  %_t15 = alloca i64, align 8
  br label %body

body:                                             ; preds = %entry
  %_t0 = call i64 @choose(i64 2)
  store i64 %_t0, ptr %_t1, align 8
  %_t2 = call i64 @choose(i64 9)
  store i64 %_t2, ptr %_t3, align 8
  %_t4 = load i64, ptr %_t1, align 8
  %_t5 = load i64, ptr %_t3, align 8
  %_t6 = add nsw i64 %_t4, %_t5
  store i64 %_t6, ptr %_t7, align 8
  %_t8 = call i64 @choose_char(i64 99)
  store i64 %_t8, ptr %_t9, align 8
  %_t10 = load i64, ptr %_t7, align 8
  %_t11 = load i64, ptr %_t9, align 8
  %_t12 = add nsw i64 %_t10, %_t11
  store i64 %_t12, ptr %_t13, align 8
  %_t14 = call i64 @choose_clause(i64 9)
  store i64 %_t14, ptr %_t15, align 8
  %_t16 = load i64, ptr %_t13, align 8
  %_t17 = load i64, ptr %_t15, align 8
  %_t18 = add nsw i64 %_t16, %_t17
  ret i64 %_t18
}

attributes #0 = { nosanitize_coverage "allockind"="alloc,uninitialized" }
attributes #1 = { nosanitize_coverage "allockind"="free" }
attributes #2 = { nosanitize_coverage memory(read) }
