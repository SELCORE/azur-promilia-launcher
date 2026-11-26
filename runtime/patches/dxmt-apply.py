"""Fixes applied to DXMT v0.80 before building it (runtime/build-runtime.sh dxmt).

usage: python3 -I runtime/patches/dxmt-apply.py <dxmt source dir>

DXMT v0.80 can hang the GPU for tens of seconds while drawing with geometry or tessellation
shaders, long enough for macOS to freeze the whole screen (WindowServer watchdog). Seen with
Azur Promilia on an M5 Pro; reported upstream for an M5 MacBook Air in 3Shain/dxmt#200.

1. gs/ts-marshal-loop (src/dxmt/dxmt_command.metal) - upstream aadf0fb
   gs_/ts_draw_arguments_marshal never advance `index`, so a batch of more than one task loops
   forever on the GPU.
2. gs/ts-marshal-guard (src/dxmt/dxmt_command.metal) - upstream 46911d7 + 3Shain/dxmt#200
   An empty draw underflows `(count - 1)` to 0xFFFFFFFF and the 32-bit `x * instances` wraps
   past the size check, so the GPU gets a gigantic dispatch. Treat empty draws as nothing to
   dispatch, avoid dividing by zero, and compare in 64 bits.
3. skip-empty-draws (src/d3d11/d3d11_context_impl.cpp) - upstream 46911d7
   Draw/DrawIndexed/DrawInstanced/DrawIndexedInstanced with no vertices or instances return
   before reaching the GPU.

4. build fixes for Xcode 27's Metal compiler and GCC 16 (same as upstream main).

Running it again on a patched tree is fine.
"""
import os
import sys

src = sys.argv[1]


def patch(rel, name, old, new, count=1):
    path = os.path.join(src, rel)
    text = open(path, encoding="utf-8").read()
    if new in text:
        print(f"{rel}: {name} already applied")
        return
    n = text.count(old)
    if n == 0 or (count and n != count):
        raise SystemExit(f"{rel}: patch '{name}' expected {count or 'some'} match(es), found {n}")
    open(path, "w", encoding="utf-8").write(text.replace(old, new))
    print(f"{rel}: applied {name} ({n}x)")


metal = "src/dxmt/dxmt_command.metal"

# 1. advance to the next task (both marshal kernels end their loop the same way)
patch(metal, "gs/ts-marshal-loop",
      "    if (task.end_of_command)\n      break;\n  };\n",
      "    if (task.end_of_command)\n      break;\n    index++;  /* azur: upstream aadf0fb */\n  };\n",
      2)

# 2. TS: no division by zero, no underflow, 64-bit size check
patch(metal, "ts-marshal-guard",
      "    uint patch_count_per_instance = task.draw_arguments.x / (uint)task.control_point_count;\n"
      "    uint x = (patch_count_per_instance - 1) / task.patch_per_group + 1;\n"
      "    if (x * task.draw_arguments.y > task.max_object_threadgroups) {\n",
      "    /* azur: upstream 46911d7 + 3Shain/dxmt#200 */\n"
      "    uint patch_count_per_instance = task.control_point_count\n"
      "        ? task.draw_arguments.x / (uint)task.control_point_count : 0;\n"
      "    uint x = (patch_count_per_instance && task.patch_per_group)\n"
      "        ? (patch_count_per_instance - 1) / task.patch_per_group + 1 : 0;\n"
      "    if (!x || !task.draw_arguments.y ||\n"
      "        (ulong)x * (ulong)task.draw_arguments.y > task.max_object_threadgroups) {\n")

# 2. GS: same for the geometry shader marshal
patch(metal, "gs-marshal-guard",
      "    uint x = (task.draw_arguments.x - 1) / task.vertex_count_per_warp + 1;\n"
      "    if (x * task.draw_arguments.y > task.max_object_threadgroups) {\n",
      "    /* azur: upstream 46911d7 + 3Shain/dxmt#200 */\n"
      "    uint x = (task.draw_arguments.x && task.vertex_count_per_warp)\n"
      "        ? (task.draw_arguments.x - 1) / task.vertex_count_per_warp + 1 : 0;\n"
      "    if (!x || !task.draw_arguments.y ||\n"
      "        (ulong)x * (ulong)task.draw_arguments.y > task.max_object_threadgroups) {\n")

# 3. empty draws never reach the GPU
ctx = "src/d3d11/d3d11_context_impl.cpp"
patch(ctx, "skip-empty-draw",
      "  Draw(UINT VertexCount, UINT StartVertexLocation) override {\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n",
      "  Draw(UINT VertexCount, UINT StartVertexLocation) override {\n"
      "    if (unlikely(!VertexCount))  /* azur: upstream 46911d7 */\n"
      "      return;\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n")
patch(ctx, "skip-empty-draw-indexed",
      "  DrawIndexed(UINT IndexCount, UINT StartIndexLocation, INT BaseVertexLocation) override {\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n",
      "  DrawIndexed(UINT IndexCount, UINT StartIndexLocation, INT BaseVertexLocation) override {\n"
      "    if (unlikely(!IndexCount))  /* azur: upstream 46911d7 */\n"
      "      return;\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n")
patch(ctx, "skip-empty-draw-instanced",
      "      override {\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n\n"
      "    WMTPrimitiveType Primitive;\n",
      "      override {\n"
      "    if (unlikely(!VertexCountPerInstance || !InstanceCount))  /* azur: upstream 46911d7 */\n"
      "      return;\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n\n"
      "    WMTPrimitiveType Primitive;\n")
patch(ctx, "skip-empty-draw-indexed-instanced",
      "      UINT StartInstanceLocation\n"
      "  ) override {\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n",
      "      UINT StartInstanceLocation\n"
      "  ) override {\n"
      "    if (unlikely(!IndexCountPerInstance || !InstanceCount))  /* azur: upstream 46911d7 */\n"
      "      return;\n"
      "    std::lock_guard<mutex_t> lock(mutex);\n")

# 4. build fixes for newer toolchains (both as in upstream main)
#    - Xcode 27's Metal compiler changed the internal atomic builtin; use the public API
patch("src/airconv/shaders/air_tessellation.metal", "metal-atomic-api",
      "  return __metal_atomic_fetch_add_explicit(out_count, 1, int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);\n",
      "  return atomic_fetch_add_explicit(reinterpret_cast<threadgroup atomic_int *>(out_count), 1, memory_order_relaxed);\n")
#    - GCC 16 no longer pulls in <iomanip> indirectly
patch("src/util/com/com_guid.cpp", "include-iomanip",
      "#include <mutex>\n#include <unordered_set>\n",
      "#include <iomanip>\n#include <mutex>\n#include <unordered_set>\n")

print("all dxmt patches applied")
