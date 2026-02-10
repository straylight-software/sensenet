// flash_attn.cpp - Flash Attention with Online Softmax
//
// Memory-efficient attention without materializing N^2 matrix.
// Uses online softmax for numerical stability.
//
// Target: sm_90+

#include <cuda_fp16.h>
#include <cuda_runtime.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <limits>
#include <random>
#include <vector>

namespace straylight::nv {

// ════════════════════════════════════════════════════════════════════════════════
// Flash Attention Block Sizes
// ════════════════════════════════════════════════════════════════════════════════

constexpr int Br = 32; // Query block size
constexpr int Bc = 32; // Key block size

// ════════════════════════════════════════════════════════════════════════════════
// Flash Attention Kernel
// ════════════════════════════════════════════════════════════════════════════════

__global__ void flash_attention_kernel(const float* __restrict__ Q, // [N, D]
                                       const float* __restrict__ K, // [N, D]
                                       const float* __restrict__ V, // [N, D]
                                       float* __restrict__ O,       // [N, D]
                                       float* __restrict__ L, // [N] - log-sum-exp for each row
                                       int N, int D, float scale) {
  int qRow = blockIdx.x * Br + threadIdx.y; // Which query row
  int d = threadIdx.x;                      // Which dimension (assumes D <= 32)

  if (qRow >= N || d >= D)
    return;

  // Per-row state for online softmax
  float m_i = -INFINITY; // Running max
  float l_i = 0.0f;      // Running sum of exp
  float acc = 0.0f;      // Accumulator for output

  // Shared memory for K, V tiles
  __shared__ float smem_K[Bc * 32]; // Max D = 32
  __shared__ float smem_V[Bc * 32];

  // Iterate over K, V blocks
  for (int kStart = 0; kStart < N; kStart += Bc) {
    int kLen = min(Bc, N - kStart);

    // Load K, V tile (collaborative load)
    if (threadIdx.y < kLen && d < D) {
      smem_K[threadIdx.y * 32 + d] = K[(kStart + threadIdx.y) * D + d];
      smem_V[threadIdx.y * 32 + d] = V[(kStart + threadIdx.y) * D + d];
    }
    __syncthreads();

    // Compute scores for this query against keys in block
    float q_d = Q[qRow * D + d];

    for (int k = 0; k < kLen; k++) {
      // Dot product Q[qRow] * K[kStart + k]
      float score = 0.0f;
      for (int dd = 0; dd < D; dd++) {
        float q_dd = (dd == d) ? q_d : Q[qRow * D + dd];
        score += q_dd * smem_K[k * 32 + dd];
      }
      score *= scale;

      // Online softmax update
      float m_new = fmaxf(m_i, score);
      float exp_old = expf(m_i - m_new);
      float exp_new = expf(score - m_new);

      // Rescale accumulator and add new contribution
      acc = acc * exp_old + exp_new * smem_V[k * 32 + d];
      l_i = l_i * exp_old + exp_new;
      m_i = m_new;
    }
    __syncthreads();
  }

  // Normalize and store output
  if (l_i > 0.0f) {
    O[qRow * D + d] = acc / l_i;
  }
  if (d == 0) {
    L[qRow] = m_i + logf(l_i); // log-sum-exp
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// Reference Attention
// ════════════════════════════════════════════════════════════════════════════════

void reference_attention(const std::vector<float>& Q, const std::vector<float>& K,
                         const std::vector<float>& V, std::vector<float>& O, int N, int D,
                         float scale) {
  for (int i = 0; i < N; i++) {
    // Compute scores
    std::vector<float> scores(N);
    float maxScore = -INFINITY;

    for (int j = 0; j < N; j++) {
      float s = 0.0f;
      for (int d = 0; d < D; d++) {
        s += Q[i * D + d] * K[j * D + d];
      }
      scores[j] = s * scale;
      maxScore = std::max(maxScore, scores[j]);
    }

    // Softmax
    float sumExp = 0.0f;
    for (int j = 0; j < N; j++) {
      scores[j] = std::exp(scores[j] - maxScore);
      sumExp += scores[j];
    }
    for (int j = 0; j < N; j++) {
      scores[j] /= sumExp;
    }

    // Output
    for (int d = 0; d < D; d++) {
      float sum = 0.0f;
      for (int j = 0; j < N; j++) {
        sum += scores[j] * V[j * D + d];
      }
      O[i * D + d] = sum;
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// Test
// ════════════════════════════════════════════════════════════════════════════════

auto check(cudaError_t err, const char* op) -> bool {
  if (err != cudaSuccess) {
    std::printf("  %s: %s\n", op, cudaGetErrorString(err));
    return false;
  }
  return true;
}

auto test_flash_attention() -> bool {
  constexpr int N = 64; // Sequence length
  constexpr int D = 32; // Head dimension
  float scale = 1.0f / std::sqrt(static_cast<float>(D));

  std::vector<float> h_Q(N * D), h_K(N * D), h_V(N * D);
  std::vector<float> h_O(N * D, 0.0f), h_L(N, 0.0f), h_ref(N * D);

  std::mt19937 rng(42);
  std::uniform_real_distribution<float> dist(-0.5f, 0.5f);

  for (int i = 0; i < N * D; i++) {
    h_Q[i] = dist(rng);
    h_K[i] = dist(rng);
    h_V[i] = dist(rng);
  }

  reference_attention(h_Q, h_K, h_V, h_ref, N, D, scale);

  float *d_Q, *d_K, *d_V, *d_O, *d_L;
  if (!check(cudaMalloc(&d_Q, N * D * sizeof(float)), "malloc Q"))
    return false;
  if (!check(cudaMalloc(&d_K, N * D * sizeof(float)), "malloc K"))
    return false;
  if (!check(cudaMalloc(&d_V, N * D * sizeof(float)), "malloc V"))
    return false;
  if (!check(cudaMalloc(&d_O, N * D * sizeof(float)), "malloc O"))
    return false;
  if (!check(cudaMalloc(&d_L, N * sizeof(float)), "malloc L"))
    return false;

  cudaMemcpy(d_Q, h_Q.data(), N * D * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_K, h_K.data(), N * D * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_V, h_V.data(), N * D * sizeof(float), cudaMemcpyHostToDevice);
  cudaMemset(d_O, 0, N * D * sizeof(float));

  dim3 block(D, Br);
  dim3 grid((N + Br - 1) / Br);

  flash_attention_kernel<<<grid, block>>>(d_Q, d_K, d_V, d_O, d_L, N, D, scale);

  if (!check(cudaGetLastError(), "kernel")) {
    cudaFree(d_Q);
    cudaFree(d_K);
    cudaFree(d_V);
    cudaFree(d_O);
    cudaFree(d_L);
    return false;
  }

  cudaDeviceSynchronize();
  cudaMemcpy(h_O.data(), d_O, N * D * sizeof(float), cudaMemcpyDeviceToHost);

  cudaFree(d_Q);
  cudaFree(d_K);
  cudaFree(d_V);
  cudaFree(d_O);
  cudaFree(d_L);

  float max_err = 0.0f;
  for (int i = 0; i < N * D; i++) {
    max_err = std::max(max_err, std::abs(h_O[i] - h_ref[i]));
  }

  std::printf("  flash_attention N=%d D=%d max_err=%.6f\n", N, D, max_err);
  return max_err < 0.01f;
}

auto main_impl() -> int {
  int count = 0;
  cudaGetDeviceCount(&count);

  if (count == 0) {
    std::printf("flash_attn: no devices, compilation ok\n");
    return 0;
  }

  cudaDeviceProp props;
  cudaGetDeviceProperties(&props, 0);
  std::printf("flash_attn on %s (sm_%d%d)\n", props.name, props.major, props.minor);

  if (!test_flash_attention()) {
    std::printf("FAILED\n");
    return 1;
  }

  std::printf("flash_attn: pass\n");
  return 0;
}

} // namespace straylight::nv

int main() {
  return straylight::nv::main_impl();
}
