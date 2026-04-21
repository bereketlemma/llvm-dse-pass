; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Strategy 3: a store followed by lifetime.end with no intervening read → dead.

define void @store_before_lifetime_end() {
; CHECK-LABEL: @store_before_lifetime_end
; CHECK: alloca
; CHECK: lifetime.start
; CHECK-NOT: store i32 42
; CHECK: lifetime.end
; CHECK: ret void
  %tmp = alloca i32, align 4
  call void @llvm.lifetime.start.p0(i64 4, ptr %tmp)
  store i32 42, ptr %tmp, align 4
  call void @llvm.lifetime.end.p0(i64 4, ptr %tmp)
  ret void
}

; Negative test: store is read before lifetime.end.
define i32 @store_read_before_lifetime_end() {
; CHECK-LABEL: @store_read_before_lifetime_end
; CHECK: store i32 42
; CHECK: load
; CHECK: lifetime.end
  %tmp = alloca i32, align 4
  call void @llvm.lifetime.start.p0(i64 4, ptr %tmp)
  store i32 42, ptr %tmp, align 4
  %v = load i32, ptr %tmp, align 4
  call void @llvm.lifetime.end.p0(i64 4, ptr %tmp)
  ret i32 %v
}

declare void @llvm.lifetime.start.p0(i64, ptr nocapture)
declare void @llvm.lifetime.end.p0(i64, ptr nocapture)
