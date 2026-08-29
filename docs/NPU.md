# The NPU

Every Core Ultra in this repository has a neural accelerator on the SoC, and on
Linux it works out of the box: the driver is in mainline, the firmware is in
`linux-firmware`, nothing here needs a patch. This page is keyed to the **NPU
generation**, not to a laptop model.

**Before you spend an evening on it, the conclusion.** The NPU is slower than
the same machine's integrated GPU at every language-model workload measured
here, and ten to twenty times slower at processing a prompt. It is not the
engine to put a chat or a coding agent on. It is the engine for small,
continuous, low-power work that should not tie up the GPU. The numbers are in
[what it is actually good for](#what-the-npu-is-actually-good-for).

Setup below is copy-paste, in order. Reference material is [after it](#reference).

---

# Setup

## 1. Check the hardware

```sh
bash tools/npu-status.sh
```

```
NPU        Intel Corporation Core Ultra Processors (Series 3) NPU (rev 04)
slot       0000:00:0b.0
driver     intel_vpu 1.0.0 7.1.8-1-cachyos
firmware   intel/vpu/vpu_50xx_v1.bin
max clock  2050 MHz

busy   0.0%   clock     0 MHz   power D3hot     mem 65.5 MiB    total busy 42.3 s
```

A firmware line, a `max clock`, and `power D3hot` mean the hardware is healthy.
`clock 0 MHz` at idle is correct, not a fault: `D3hot` is the NPU switched off
until something asks for it.

If that fails, find out which half is missing:

```sh
lspci -nnk | grep -iA3 'Processing accelerators' || echo "no NPU on this machine"
```

| What you see | What to do |
|---|---|
| `Kernel driver in use: intel_vpu` | fine, the tool should have worked |
| device listed, no `Kernel driver` line | `sudo modprobe intel_vpu` |
| nothing listed | this CPU has no NPU, stop here |

## 2. Install

```sh
sudo pacman -S --needed \
    openvino openvino-intel-npu-plugin openvino-intel-gpu-plugin python-openvino
```

All in the official repositories: no AUR, no Intel installer, no oneAPI
download. This pulls in `intel-npu-driver`, `intel-npu-compiler` and
`level-zero-loader` as dependencies.

The GPU plugin is not optional here. You will want to compare against the GPU,
and that comparison is the point of the page.

## 3. Verify the stack

```sh
python - <<'EOF'
import openvino as ov
core = ov.Core()
for d in core.available_devices:
    print(f"{d:4} {core.get_property(d, 'FULL_DEVICE_NAME')}")
EOF
```

```
CPU  Intel(R) Core(TM) Ultra X9 388H
GPU  Intel(R) Arc(TM) B390 GPU (iGPU)
NPU  Intel(R) AI Boost
```

**`NPU` missing from that list is a missing package, not broken hardware.** See
[how the stack fits together](#how-the-stack-fits-together).

## 4. Set up a runtime and get a model

```sh
python -m venv ~/ov-npu
~/ov-npu/bin/pip install openvino-genai openvino-tokenizers huggingface_hub
```

```sh
mkdir -p ~/models
~/ov-npu/bin/hf download OpenVINO/Qwen3-8B-int4-cw-ov \
    --local-dir ~/models/qwen3-8b-npu
```

**The `-cw-` in that name is mandatory.** It means channel-wise INT4, the only
weight layout the NPU compiler accepts. A model named `...-int4-ov` without it
will not compile. See [the model format rule](#the-model-format-rule).

## 5. Run something on it

```sh
~/ov-npu/bin/python - <<'EOF'
import os
import openvino_genai as ov_genai

pipe = ov_genai.LLMPipeline(
    os.path.expanduser("~/models/qwen3-8b-npu"), "NPU",
    MAX_PROMPT_LEN=1024,      # both are required on NPU and have no default
    MIN_RESPONSE_LEN=256,
)
print(pipe.generate(["Write a Python function that reverses a linked list."]))
EOF
```

The `expanduser` is not decoration: the pipeline takes a real path and will not
expand a `~` itself.

First compile is slow because it reads the whole model off disk, about 26 s for
this 5 GB one, then roughly 3 s once the file is in page cache. There is no
compiled-blob cache on disk to warm up.

`MAX_PROMPT_LEN` is a hard ceiling, not a hint. The NPU compiles a **static**
graph, so context length is fixed at compile time.

## 6. Serve it over an API

Editors and coding agents all speak one thing: an **OpenAI-compatible HTTP
endpoint**. Which device is underneath does not change the client config, which
is what makes the device a decision you can revisit.

**On the NPU** the only server that does this is OpenVINO Model Server:

```sh
docker run --rm -p 8000:8000 \
  --device /dev/accel --device /dev/dri \
  -v ${HOME}/models:/models:rw \
  openvino/model_server:latest-gpu \
  --source_model OpenVINO/Qwen3-8B-int4-cw-ov \
  --model_repository_path /models --rest_port 8000 --target_device NPU
```

> From the vendor's documentation; it has not been run on this machine, unlike
> everything else on this page. `--device /dev/accel` is the part people leave
> out, and without it the container has a `--target_device NPU` and no NPU.

**On the GPU**, which is what you want for anything interactive, no container:

```sh
sudo pacman -S --needed llama-cpp ggml-vulkan ggml-cpu
```

```sh
llama-server -m ~/models/model.gguf -ngl 99 -c 16384 \
             --host 127.0.0.1 --port 8080 --jinja --reasoning-budget 0
```

Check it before wiring anything to it:

```sh
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"local","messages":[{"role":"user","content":"say OK"}],"max_tokens":16}'
```

## 7. Wire an editor to it

```jsonc
// ~/.config/opencode/opencode.json
{
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": { "local-model": {} }
    }
  }
}
```

| Rule | Why |
|---|---|
| `baseURL` goes **inside** `options` | at the provider root, requests go to a path that does not exist |
| name the provider anything but `openai` | the built-in `openai` provider carries a fixed model list |
| `--jinja` on the server | without it the tool-call template is never applied and every agent that invokes a tool fails |
| pick a model that does tool calls | Qwen2.5-Coder-7B printed malformed pseudo-JSON as prose, `tool_calls: null`. Qwen3, down to 1.7B, returned a correct `tool_calls` array. "Coder" in the name does not mean agentic |
| turn thinking off | same request, same one-line answer: 189 tokens with reasoning, 20 without |

## 8. Watch it work

```sh
bash tools/npu-status.sh -w
```

```
busy  24.5%   clock  2050 MHz   power D0        mem 4.7 GiB     total busy 42.8 s
busy  93.7%   clock  2050 MHz   power D0        mem 5.7 GiB     total busy 44.7 s
busy 100.0%   clock  2050 MHz   power D0        mem 5.7 GiB     total busy 46.7 s
```

`sensors` will never show any of this. See
[why `sensors` is empty](#why-sensors-is-empty).

---

# Reference

## Which machines have one

| NPU | Firmware | SoC | Core Ultra | Profiles here |
|---|---|---|---|---|
| **3** | `vpu_37xx_v1.bin` | Meteor Lake | 1xxH | [`dra-xx-hunter`](../devices/dra-xx-hunter.conf) (125H, 155H) |
| **4** | `vpu_40xx_v1.bin` | Lunar Lake, Arrow Lake | 2xx | none yet |
| **5** | `vpu_50xx_v1.bin` | Panther Lake | 3xxH | [`zqc-p`](../devices/zqc-p.conf) (X9 388H, 5 338H), [`xwc-p`](../devices/xwc-p.conf) (5 338H) |

The driver carries all three and loads whichever matches. A Core Ultra not
listed here almost certainly still works; the profile just does not record the
CPU yet.

Vendor figures, for scale: NPU 3 is rated around 11 TOPS INT8, NPU 5 around 50.
Treat those as marketing units, and the measurements below as what the hardware
did.

## How the stack fits together

`NPU` is not a feature of OpenVINO, it is a **plugin that has to exist as a
file**. `plugins.xml` names all seven regardless of what is installed, so a
device missing from `available_devices` means a missing package:

| File | Package |
|---|---|
| `plugins.xml`, declares AUTO BATCH CPU GPU HETERO MULTI NPU | `openvino` |
| `libopenvino_intel_cpu_plugin.so` | `openvino` |
| `libopenvino_intel_gpu_plugin.so` | `openvino-intel-gpu-plugin` |
| `libopenvino_intel_npu_plugin.so` | `openvino-intel-npu-plugin` |

Underneath the plugin is a second stack that is **not** part of OpenVINO. The
plugin talks Level Zero, and Level Zero is a dispatcher loading a per-vendor
backend:

| Library | Package | Role |
|---|---|---|
| `libze_loader.so.1` | `level-zero-loader` | the dispatcher everything links against |
| `libze_intel_npu.so.1` | `intel-npu-driver` | the NPU backend behind it |
| `libze_intel_gpu.so.1` | `intel-compute-runtime` | the GPU backend, for comparison |
| `libopenvino_intel_npu_compiler.so` | `intel-npu-compiler` | builds the NPU blob; this is what fails below |

**`AUTO` will not give you the NPU.** Its ranking is its own, and naming the
NPU first does not change it:

```
AUTO:NPU,GPU     -> EXECUTION_DEVICES = ['GPU.0']
AUTO             -> EXECUTION_DEVICES = ['GPU.0']
```

Intel's own device chooser, handed an NPU and told to prefer it, takes the GPU.
Ask for `"NPU"` by name, or you will benchmark the wrong device and never be
told. `HETERO` splits a model across devices; `MULTI` and `BATCH` load but
neither helps one interactive generation.

**The pip wheel is a separate universe.** `pip install openvino-genai` brings
its own complete set of plugins, so the venv from step 4 ignores the packages
from step 2 and can run a different OpenVINO version (2026.3.1 against
2026.3.0 here) without either noticing. What the wheel does *not* bundle is
Level Zero, so `level-zero-loader` and `intel-npu-driver` must still be
installed system-wide for a venv to see an NPU at all.

Two more traps. `openvino.runtime` was **removed in OpenVINO 2026** and most
tutorials still import it; the current spelling is `from openvino import
opset13`. And the NPU plugin advertises `OPTIMIZATION_CAPABILITIES = ['FP16',
'INT8', 'EXPORT_IMPORT']`, which does not mention INT4 even though INT4 is what
you must use. Read nothing into that list.

## The model format rule

The NPU needs INT4 weights that are **symmetric** and **channel-wise**, group
size `-1`. Group-wise INT4, which is what almost everything on Hugging Face
ships, fails like this:

```
[vpux-compiler] UnrollDistributedOps Pass failed : Can't convert 188 Bit to Byte
[vpux-compiler] Failed Pass UnrollDistributedOps on Operation loc(...["main"])
Compilation failed. Level0 pfnCreate2 result: ZE_RESULT_ERROR_INVALID_ARGUMENT
```

Nothing there mentions quantization, group size, or the model. It is the
compiler failing to lay out a group-quantized tensor, and the fix is a
different file, not a different flag.

### The ready-made ones

Intel publishes about 440 models under
[`OpenVINO`](https://huggingface.co/OpenVINO). **Seven** are channel-wise:

| | |
|---|---|
| `Qwen3-8B-int4-cw-ov` | the largest and newest that works |
| `Phi-3.5-mini-instruct-int4-cw-ov` | best speed-to-quality of the small ones |
| `Phi-3-mini-4k-instruct-int4-cw-ov` | superseded by the above |
| `Mistral-7B-Instruct-v0.2` / `v0.3-int4-cw-ov` | older generation |
| `gemma-3-4b-it-int4-cw-ov` | **gated**: without a Hugging Face login and an accepted licence you silently download only the README |
| `Qwen3-Embedding-0.6B-int4-cw-ov` | embeddings, not chat |

That is the entire ecosystem, and it stops well short of the current generation
of open-weight models. For anything newer, convert it yourself.

### Converting your own model

```sh
~/ov-npu/bin/pip install "optimum-intel[openvino]" nncf
```

```sh
~/ov-npu/bin/optimum-cli export openvino \
    --model Qwen/Qwen3-1.7B \
    --task text-generation-with-past \
    --weight-format int4 --sym --group-size -1 --ratio 1.0 \
    ~/models/qwen3-1.7b-npu
```

`--sym --group-size -1` is the whole point. `--ratio 1.0` stops the compressor
leaving layers at higher precision. Confirm from the table it prints:

```
│ int8_asym, per-channel    │ 18% (1 / 197)    │   0% (0 / 196) │
│ int4_sym, per-channel     │ 82% (196 / 197)  │ 100% (196 / 196) │
```

`int4_sym, per-channel` on essentially every layer means it will compile. One
layer left at int8 is normal, that is the embedding table.

## What the NPU is actually good for

Core Ultra X9 388H, NPU 5, against the same machine's Arc B390 iGPU. Same model
files, same prompt, 128 new tokens, after a warm-up pass. `TTFT` is the prompt
being processed; `tok/s` is generation after that.

| Model | | TTFT | tok/s |
|---|---|---|---|
| Qwen3-8B int4-cw | **NPU** | 1853 ms | 11.7 |
| | GPU | 122 ms | 13.0 |
| Phi-3.5-mini int4-cw | **NPU** | 1135 ms | 19.4 |
| | GPU | 88 ms | 26.8 |
| Qwen3-1.7B, converted here | **NPU** | 482 ms | 35.9 |
| | GPU | 48 ms | 47.5 |

Read the TTFT column first. **The NPU is ten to twenty times slower at
processing a prompt**, on every model, and the gap does not close as the model
grows. Generation is the flattering case, and even there the NPU only draws
level on the largest model, where both engines are stuck waiting on memory
bandwidth.

An agent that resends thousands of tokens of context on every step lives in
that TTFT column. Serve agents from the GPU.

What the NPU gives back is power: a fraction of the GPU's draw for the same
job, without taking the GPU away from the desktop. That is what it was built
for — noise suppression, camera effects, wake words, background indexing —
steady low-power inference, not the largest model that will fit.

## Which software can reach it

Most of the local-inference world cannot. The NPU is not a GPU, so nothing
going through Vulkan, OpenCL, ROCm or CUDA sees it, and that is nearly
everything.

| | NPU | Intel GPU | Serves an API | Checked how |
|---|---|---|---|---|
| **OpenVINO GenAI** | **yes** | yes | no, a library | measured here |
| **OpenVINO Model Server** | **yes** | yes | **yes** | vendor docs |
| `llama.cpp` + `ggml-openvino` | **yes** | yes | yes | packaged, not run here |
| `llama.cpp` + `ggml-vulkan` | no | yes | yes | measured here |
| `ollama` + `ollama-vulkan` | no | yes | yes | measured here |
| vLLM | no | yes, XPU build | yes | vendor docs |
| `ramalama` | no | yes, Vulkan | yes | in `extra`, not run here |
| LM Studio | no | yes, Vulkan | yes | closed source |

Two of those have a sting.

`ggml-openvino` is the only way to put a **GGUF** file on the NPU. The package
is 400 KB; its dependency `intel-oneapi-toolkit` is about **9 GB installed**.
That is the price of running a model slower than the same GGUF runs on the GPU
through `ggml-vulkan`, which costs 52 MB.

`ollama` finds the integrated GPU and throws it away. Nothing in its normal
output says so; it is one line in the log:

```
dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1
```

With `OLLAMA_IGPU_ENABLE=1` it reports `type=iGPU total="23.2 GiB"` and works.
It still has no NPU path.

## Why `sensors` is empty

Not a misconfiguration, and no config file can add it:

- `intel_vpu` **registers no hwmon device**, so `libsensors` has nothing to
  enumerate.
- There is no thermal zone and no RAPL domain for the NPU. It has **no
  temperature and no power reading to expose**, on any current kernel.
- hwmon has no channel type for "utilization" anyway, so even a driver that
  wanted to report the one useful number could not do it through `sensors`.

The CPU has both because its silicon exposes per-core thermal diodes over a
documented MSR, and because the kernel *schedules* CPU work and so counts it
for free. NPU work is scheduled by firmware on the device — `Scheduler mode:
HW` — and the driver never sees individual jobs, only the aggregate the
firmware reports.

What does exist is in PCI sysfs, and `tools/npu-status.sh` reads it:

| Field | Source | Meaning |
|---|---|---|
| `busy %` | `npu_busy_time_us` | **computed, not read.** A microsecond counter since boot, so a percentage exists only between two samples |
| `clock` | `npu_current_frequency_mhz` | `0` when idle; under load it pins straight to maximum, no ramp was ever observed |
| `power` | PCI `power_state` | `D3hot` idle, `D0` working; proof that runtime PM works |
| `mem` | `npu_memory_utilization` | host memory the NPU context holds. The NPU has no memory of its own |
| `total busy` | `npu_busy_time_us` | cumulative since boot |

That last one answers a question worth asking on its own. On a machine where
nothing has ever driven the NPU it reads `0.0 s`, and that single number
separates "my software is not using the NPU" from "the NPU is broken" faster
than anything else here. No root needed for any of it.

`nputop` and `intel-npu-top` on GitHub read the same counter; neither is
packaged for Arch. `btop` has an open pull request for Intel NPU utilization
that has not landed as of 1.4.7.

## Known limits

| | |
|---|---|
| Group-quantized INT4 does not compile | use channel-wise |
| Context length is fixed at compile time | `MAX_PROMPT_LEN`, chosen up front |
| No OpenCL, Vulkan or SYCL path | OpenVINO or nothing, so most local-inference software cannot see it |
| `AUTO` silently prefers the GPU | ask for `"NPU"` by name |
| No temperature, no power telemetry | the driver exposes neither |
| `llama.cpp` can reach it, expensively | 9 GB of oneAPI to run slower than the GPU |
| Only one server speaks OpenAI over it | OpenVINO Model Server; `LLMPipeline` is a library with no tools API |
| 32-bit userspace | not supported, and not coming |
