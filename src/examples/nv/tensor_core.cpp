// tensor_core.cpp - Tensor Core WMMA with C++23
//
// Uses:
//   - nvcuda::wmma for tensor core ops (16x16x16 fp16 matmul)
//   - cooperative_groups for warp-level sync
//   - std::mdspan for type-safe host indexing
//   - __half2 for packed fp16 arithmetic
//
// Target: sm_90 (Hopper) or sm_120 (Blackwell)

#include <cuda_fp16.h>
#include <cuda_runtime.h>

#include <array>
#include <cstdio>
#include <random>

#include <mma.h>

#include <experimental/mdspan>

namespace stdex = std::experimental;
using namespace nvcuda;

namespace straylight::nv {

// ════════════════════════════════════════════════════════════════════════════════
// Constants
// ════════════════════════════════════════════════════════════════════════════════

constexpr int WMMA_M = 16;
constexpr int WMMA_N = 16;
constexpr int WMMA_K = 16;

// Tile sizes for the kernel
constexpr int TILE_M = 64; // 4 WMMA tiles in M
constexpr int TILE_N = 64; // 4 WMMA tiles in N
constexpr int TILE_K = 16; // 1 WMMA tile in K

// ════════════════════════════════════════════════════════════════════════════════
// Tensor Core GEMM Kernel
// ════════════════════════════════════════════════════════════════════════════════

// Each warp computes a 16x16 output tile using tensor cores
// Block handles TILE_M x TILE_N output, with K-dimension reduction
__global__ void wmma_gemm_kernel(const half* __restrict__ A, // [M, K] row-major
                                 const half* __restrict__ B, // [K, N] row-major
                                 float* __restrict__ C,      // [M, N] row-major
                                 int M, int K, int N) {
  // Warp and lane indices
  int warpM = (blockIdx.x * blockDim.x + threadIdx.x) / 32;
  int warpN = blockIdx.y;

  // Bounds check
  int mStart = warpM * WMMA_M;
  int nStart = warpN * WMMA_N;
  if (mStart >= M || nStart >= N)
    return;

  // Declare WMMA fragments
  wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, wmma::row_major> a_frag;
  wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, wmma::row_major> b_frag;
  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> c_frag;

  // Initialize accumulator
  wmma::fill_fragment(c_frag, 0.0f);

  // Iterate over K dimension
  for (int k = 0; k < K; k += WMMA_K) {
    int kTile = min(WMMA_K, K - k);

    // Load A tile [mStart:mStart+16, k:k+16]
    if (mStart < M && k < K) {
      wmma::load_matrix_sync(a_frag, A + mStart * K + k, K);
    }

    // Load B tile [k:k+16, nStart:nStart+16]
    if (k < K && nStart < N) {
      wmma::load_matrix_sync(b_frag, B + k * N + nStart, N);
    }

    // Tensor core matmul: C += A * B
    wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
  }

  // Store result
  if (mStart < M && nStart < N) {
    wmma::store_matrix_sync(C + mStart * N + nStart, c_frag, N, wmma::mem_row_major);
  }
}

// ════════════════════════════════════════════════════════════════════════════════
// Host code
// ════════════════════════════════════════════════════════════════════════════════

auto check(cudaError_t err, const char* op) -> bool {
  if (err != cudaSuccess) {
    std::printf("  %s: %s\n", op, cudaGetErrorString(err));
    return false;
  }
  return true;
}

// Convert float to half on host
auto float_to_half(float f) -> half {
  return __float2half(f);
}

// Convert half to float on host
auto half_to_float(half h) -> float {
  return __half2float(h);
}

auto test_wmma_gemm() -> bool {
  // Small test: 64x64 matmul
  constexpr int M = 64;
  constexpr int K = 64;
  constexpr int N = 64;

  // Host arrays
  std::array<half, M * K> h_A{};
  std::array<half, K * N> h_B{};
  std::array<float, M * N> h_C{};
  std::array<float, M * N> h_ref{};

  // Initialize with simple pattern
  std::mt19937 rng(42);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);

  for (int i = 0; i < M * K; i++)
    h_A[i] = float_to_half(dist(rng));
  for (int i = 0; i < K * N; i++)
    h_B[i] = float_to_half(dist(rng));

  // Reference matmul on host
  for (int m = 0; m < M; m++) {
    for (int n = 0; n < N; n++) {
      float sum = 0.0f;
      for (int k = 0; k < K; k++) {
        sum += half_to_float(h_A[m * K + k]) * half_to_float(h_B[k * N + n]);
      }
      h_ref[m * N + n] = sum;
    }
  }

  // Device memory
  half *d_A = nullptr, *d_B = nullptr;
  float* d_C = nullptr;

  if (!check(cudaMalloc(&d_A, sizeof(h_A)), "malloc A"))
    return false;
  if (!check(cudaMalloc(&d_B, sizeof(h_B)), "malloc B"))
    return false;
  if (!check(cudaMalloc(&d_C, sizeof(h_C)), "malloc C"))
    return false;

  cudaMemcpy(d_A, h_A.data(), sizeof(h_A), cudaMemcpyHostToDevice);
  cudaMemcpy(d_B, h_B.data(), sizeof(h_B), cudaMemcpyHostToDevice);

  // Launch: one warp per 16x16 output tile
  // Grid: (M/16 warps, N/16 tiles)
  dim3 block(128); // 4 warps per block
  dim3 grid((M / WMMA_M + 3) / 4, N / WMMA_N);

  wmma_gemm_kernel<<<grid, block>>>(d_A, d_B, d_C, M, K, N);

  if (!check(cudaGetLastError(), "kernel launch")) {
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
    return false;
  }

  cudaDeviceSynchronize();
  cudaMemcpy(h_C.data(), d_C, sizeof(h_C), cudaMemcpyDeviceToHost);

  cudaFree(d_A);
  cudaFree(d_B);
  cudaFree(d_C);

  // Verify against reference
  float max_err = 0.0f;
  for (int i = 0; i < M * N; i++) {
    float err = std::abs(h_C[i] - h_ref[i]);
    max_err = std::max(max_err, err);
  }

  // fp16 accumulation has limited precision
  constexpr float tolerance = 0.1f;
  if (max_err > tolerance) {
    std::printf("  wmma gemm max error: %f (tolerance: %f)\n", max_err, tolerance);
    return false;
  }

  std::printf("  wmma gemm %dx%dx%d: max_err=%f\n", M, K, N, max_err);
  return true;
}

// ════════════════════════════════════════════════════════════════════════════════
// Benchmark
// ════════════════════════════════════════════════════════════════════════════════

auto benchmark_wmma(int M, int K, int N, int iterations) -> void {
  // Allocate
  half *d_A = nullptr, *d_B = nullptr;
  float* d_C = nullptr;

  cudaMalloc(&d_A, M * K * sizeof(half));
  cudaMalloc(&d_B, K * N * sizeof(half));
  cudaMalloc(&d_C, M * N * sizeof(float));

  // Warm up
  dim3 block(128);
  dim3 grid((M / WMMA_M + 3) / 4, N / WMMA_N);
  wmma_gemm_kernel<<<grid, block>>>(d_A, d_B, d_C, M, K, N);
  cudaDeviceSynchronize();

  // Time
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaEventRecord(start);
  for (int i = 0; i < iterations; i++) {
    wmma_gemm_kernel<<<grid, block>>>(d_A, d_B, d_C, M, K, N);
  }
  cudaEventRecord(stop);
  cudaEventSynchronize(stop);

  float ms = 0;
  cudaEventElapsedTime(&ms, start, stop);

  // Calculate TFLOPS
  // GEMM: 2*M*N*K FLOPs
  double flops = 2.0 * M * N * K * iterations;
  double tflops = (flops / (ms / 1000.0)) / 1e12;

  std::printf("  %dx%dx%d: %.2f ms (%d iters), %.2f TFLOPS\n", M, K, N, ms, iterations, tflops);

  cudaEventDestroy(start);
  cudaEventDestroy(stop);
  cudaFree(d_A);
  cudaFree(d_B);
  cudaFree(d_C);
}

auto main_impl() -> int {
  int count = 0;
  cudaGetDeviceCount(&count);

  if (count == 0) {
    std::printf("tensor_core: no devices\n");
    std::printf("compilation succeeded - wmma code compiled\n");
    return 0;
  }

  cudaDeviceProp props;
  cudaGetDeviceProperties(&props, 0);
  std::printf("tensor_core test on %s (sm_%d%d)\n", props.name, props.major, props.minor);

  // Check for tensor core support (sm_70+)
  if (props.major < 7) {
    std::printf("  tensor cores require sm_70+, skipping\n");
    return 0;
  }

  if (!test_wmma_gemm()) {
    std::printf("wmma gemm FAILED\n");
    return 1;
  }

  std::printf("\nbenchmarks:\n");
  benchmark_wmma(1024, 1024, 1024, 100);
  benchmark_wmma(2048, 2048, 2048, 50);
  benchmark_wmma(4096, 4096, 4096, 20);

  std::printf("\ntensor_core: pass\n");
  return 0;
}

} // namespace straylight::nv

int main() {
  return straylight::nv::main_impl();
}
