; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Cross-block stores: our pass is conservative and does NOT eliminate
; stores across basic blocks (to avoid false positives on divergent paths).

define void @cross_block_overwrite(ptr %p, i1 %cond) {
; CHECK-LABEL: @cross_block_overwrite
; CHECK: store i32 1, ptr %p
; CHECK: store i32 2, ptr %p
  store i32 1, ptr %p, align 4
  br i1 %cond, label %then, label %end

then:
  store i32 2, ptr %p, align 4
  br label %end

end:
  ret void
}

; Both branches overwrite — still conservative, keep the original store.
define void @diamond_overwrite(ptr %p, i1 %cond) {
; CHECK-LABEL: @diamond_overwrite
; CHECK: store i32 0, ptr %p
; CHECK: store i32 1, ptr %p
; CHECK: store i32 2, ptr %p
  store i32 0, ptr %p, align 4
  br i1 %cond, label %left, label %right

left:
  store i32 1, ptr %p, align 4
  br label %end

right:
  store i32 2, ptr %p, align 4
  br label %end

end:
  ret void
}

; Loop: store inside loop is NOT dead even if overwritten on next iteration.
define void @loop_store(ptr %p, i32 %n) {
; CHECK-LABEL: @loop_store
; CHECK: store
  br label %loop

loop:
  %i = phi i32 [0, %0], [%next, %loop]
  store i32 %i, ptr %p, align 4
  %next = add i32 %i, 1
  %cmp = icmp slt i32 %next, %n
  br i1 %cmp, label %loop, label %exit

exit:
  ret void
}
