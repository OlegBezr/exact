//! The JNI methods of drags from other apps (LLP 1094.001 D5), expanded by
//! `canvas_jni!` inside its module, where `with` reaches the thread's host.

#[doc(hidden)]
#[macro_export]
macro_rules! canvas_jni_drop {
    () => {
        /// The drag is at (`x`, `y`) px: whether a node takes a drop there
        /// (`CanvasHost::drag_over`).
        #[no_mangle]
        pub unsafe extern "system" fn Java_dev_exact_canvas_Native_dragOver(
            _env: *mut $crate::canvas::jni_sys::JNIEnv,
            _class: $crate::canvas::jni_sys::jclass,
            x: $crate::canvas::jni_sys::jfloat,
            y: $crate::canvas::jni_sys::jfloat,
        ) -> $crate::canvas::jni_sys::jboolean {
            flag(with(|h| h.drag_over(x, y)).unwrap_or(false))
        }

        /// The drag left the window, was cancelled, or a field took it.
        #[no_mangle]
        pub unsafe extern "system" fn Java_dev_exact_canvas_Native_dragLeft(
            _env: *mut $crate::canvas::jni_sys::JNIEnv,
            _class: $crate::canvas::jni_sys::jclass,
        ) {
            with(|h| h.drag_left());
        }

        /// The drag was released at (`x`, `y`) px: the drop's number, 0 when
        /// nothing takes it (`CanvasHost::drop_released`).
        #[no_mangle]
        pub unsafe extern "system" fn Java_dev_exact_canvas_Native_dropReleased(
            _env: *mut $crate::canvas::jni_sys::JNIEnv,
            _class: $crate::canvas::jni_sys::jclass,
            x: $crate::canvas::jni_sys::jfloat,
            y: $crate::canvas::jni_sys::jfloat,
        ) -> $crate::canvas::jni_sys::jint {
            with(|h| h.drop_released(x, y)).unwrap_or(0) as $crate::canvas::jni_sys::jint
        }

        /// Drop `id`'s items arrived, as JSON: whether its target took them
        /// (`CanvasHost::drop_landed`).
        #[no_mangle]
        pub unsafe extern "system" fn Java_dev_exact_canvas_Native_dropLanded(
            env: *mut $crate::canvas::jni_sys::JNIEnv,
            _class: $crate::canvas::jni_sys::jclass,
            id: $crate::canvas::jni_sys::jint,
            items: $crate::canvas::jni_sys::jstring,
        ) -> $crate::canvas::jni_sys::jboolean {
            let items = string(env, items);
            flag(with(|h| h.drop_landed(id as u32, &items)).unwrap_or(false))
        }

        /// Which node takes a drop over node `id`: 0 none, 1 the node, 2 one
        /// above it (`CanvasHost::drop_owner`).
        #[no_mangle]
        pub unsafe extern "system" fn Java_dev_exact_canvas_Native_dropOwner(
            _env: *mut $crate::canvas::jni_sys::JNIEnv,
            _class: $crate::canvas::jni_sys::jclass,
            id: $crate::canvas::jni_sys::jint,
        ) -> $crate::canvas::jni_sys::jint {
            with(|h| h.drop_owner(id as u32)).unwrap_or(0)
        }
    };
}
