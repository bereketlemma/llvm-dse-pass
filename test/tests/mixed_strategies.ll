; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; A function that exercises multiple strategies simultaneously.

declare void @llvm.lifetime.start.p0(i64, ptr nocapture)
declare void @llvm.lifetime.end.p0(i64, ptr nocapture)

define i32 @mixed_strategies(ptr %external) {
; CHECK-LABEL: @mixed_strategies

; Strategy 1: write-only alloca — should be eliminated.
; CHECK-NOT: %dead_local
  %dead_local = alloca i32, align 4
  store i32 999, ptr %dead_local, align 4

; Strategy 2: dominated overwrite — first store should die.
; CHECK-NOT: store i32 10, ptr %external
; CHECK: store i32 20, ptr %external
  store i32 10, ptr %external, align 4
  store i32 20, ptr %external, align 4

; Strategy 3: pre-lifetime.end — store before end should die.
; CHECK: lifetime.start
; CHECK-NOT: store i32 77
; CHECK: lifetime.end
  %tmp = alloca i32, align 4
  call void @llvm.lifetime.start.p0(i64 4, ptr %tmp)
  store i32 77, ptr %tmp, align 4
  call void @llvm.lifetime.end.p0(i64 4, ptr %tmp)

; This load is from %external, which got the store i32 20 above.
; CHECK: load i32, ptr %external
  %result = load i32, ptr %external, align 4
  ret i32 %result
}

; Function with no dead stores — pass should be a no-op.
define i32 @all_stores_live(ptr %p) {
; CHECK-LABEL: @all_stores_live
; CHECK: store i32 42, ptr %p
; CHECK: load i32, ptr %p
  store i32 42, ptr %p, align 4
  %v = load i32, ptr %p, align 4
  ret i32 %v
}
