; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Strategy 2: a store is immediately overwritten by another store
; to the same location with no intervening read → the first store is dead.

define void @simple_overwrite(ptr %p) {
; CHECK-LABEL: @simple_overwrite
; CHECK-NOT: store i32 1
; CHECK: store i32 2, ptr %p
; CHECK: ret void
  store i32 1, ptr %p, align 4
  store i32 2, ptr %p, align 4
  ret void
}

define void @overwrite_with_gap(ptr %p, ptr %q) {
; CHECK-LABEL: @overwrite_with_gap
; CHECK-NOT: store i32 10, ptr %p
; CHECK: store i32 20, ptr %q
; CHECK: store i32 30, ptr %p
; CHECK: ret void
  store i32 10, ptr %p, align 4
  store i32 20, ptr %q, align 4
  store i32 30, ptr %p, align 4
  ret void
}

; Negative test: the first store IS read before being overwritten.
define i32 @store_is_read(ptr %p) {
; CHECK-LABEL: @store_is_read
; CHECK: store i32 1, ptr %p
; CHECK: load
; CHECK: store i32 2, ptr %p
  store i32 1, ptr %p, align 4
  %v = load i32, ptr %p, align 4
  store i32 2, ptr %p, align 4
  ret i32 %v
}
