About candle-vllm
=================

Home: https://github.com/EricLBuehler/candle-vllm

Package license: MIT

Feedstock license: [BSD-3-Clause](https://github.com/AnacondaRecipes/candle-vllm-feedstock/blob/main/LICENSE.txt)

Summary: Efficient platform for inference and serving local LLMs with an OpenAI compatible API server

Documentation: https://github.com/EricLBuehler/candle-vllm/blob/master/README.md

Candle-vLLM is a Rust-based model runner built on the HuggingFace candle ML framework.
It provides an OpenAI-compatible API server for running inference on large language models
with support for CUDA GPU acceleration, multi-GPU (NCCL), paged attention, and continuous
batching. It supports a wide range of model architectures including Llama, Mistral, Phi,
Qwen, Gemma, and more.

Installing candle-vllm
======================

```
conda install candle-vllm
```

Feedstock Maintainers
=====================

* [@xkong-anaconda](https://github.com/xkong-anaconda/)
