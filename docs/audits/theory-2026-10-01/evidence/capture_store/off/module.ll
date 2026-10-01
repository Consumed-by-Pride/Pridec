; ModuleID = '/home/user/theory-audit/raw-ir/capture_store/off/capture_store.bc'
source_filename = "Pride"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-p270:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

declare i64 @write(i32, ptr, i64)

; Function Attrs: nosanitize_coverage
declare ptr @malloc(i64) #0

; Function Attrs: nosanitize_coverage
declare void @free(ptr) #1

; Function Attrs: nosanitize_coverage
define i64 @retain(ptr %0, ptr %1) #2 {
entry:
  %_t0 = alloca i64, align 8
  br label %body

body:                                             ; preds = %entry
  store ptr %1, ptr %_t0, align 8
  %_t2 = getelementptr i8, ptr %0, i64 0
  %_t3 = ptrtoint ptr %_t2 to i64
  %_t4 = inttoptr i64 %_t3 to ptr
  %_t5 = load i64, ptr %_t0, align 8
  %_t6 = trunc i64 %_t5 to i8
  store i8 %_t6, ptr %_t4, align 1
  br label %k1

k1:                                               ; preds = %body
  ret i64 0
}

; Function Attrs: nosanitize_coverage
define i64 @main(i64 %0) #2 {
entry:
  br label %body

body:                                             ; preds = %entry
  ret i64 42
}

attributes #0 = { nosanitize_coverage "allockind"="alloc,uninitialized" }
attributes #1 = { nosanitize_coverage "allockind"="free" }
attributes #2 = { nosanitize_coverage }
