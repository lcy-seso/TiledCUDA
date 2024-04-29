#include "cell/copy/dyn_copy.hpp"
#include "cell/sync.hpp"
#include "cell/traits/copy.hpp"
#include "common/test_utils.hpp"

#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

namespace traits = tiledcuda::cell::traits;

namespace tiledcuda {

namespace {

DEVICE void DebugPrint(const cutlass::half_t* input, int row, int col) {
    auto* data = reinterpret_cast<const __half*>(input);

    for (int i = 0; i < row; ++i) {
        printf("[%d]:\t", i);
        for (int j = 0; j < col - 1; ++j) {
            printf("%.0f,", __half2float(data[i * col + j]));
        }
        printf("%.0f\n", __half2float(data[(i + 1) * col - 1]));
    }
    printf("\n");
}

// the host function to call the device copy function
template <typename Element, typename G2STraits, typename S2GTraits>
__global__ void Copy(const Element* src, Element* trg) {
    extern __shared__ __align__(sizeof(double)) unsigned char shared_buf[];
    auto* buf = reinterpret_cast<Element*>(shared_buf);

    int tid = threadIdx.x;

    // int rows = KeTraits::kRows;
    // int cols = KeTraits::kCols;

    // int shm_rows = KeTraits::kShmRows;
    // int shm_cols = KeTraits::kShmCols;

    // const int x_block = blockIdx.x;
    // const int y_block = blockIdx.y;

    // advance the pointer to the input data to the current CTA
    // const int offset = x_block * (shm_rows * cols) + y_block * shm_cols;

    cell::copy::copy_2d_tile_g2s(src, buf, typename G2STraits::SrcLayout{},
                                 typename G2STraits::DstLayout{},
                                 typename G2STraits::TiledCopy{}, tid);
    cell::__copy_async();
    __syncthreads();

    // if (tid == 0) {
    //     printf("tid: %d\n", tid);
    //     DebugPrint(buf, KeTraits::kRows, KeTraits::kCols);
    // }

    cell::copy::copy_2d_tile_s2g(buf, trg, typename S2GTraits::SrcLayout{},
                                 typename S2GTraits::DstLayout{},
                                 typename S2GTraits::TiledCopy{}, tid);
    cell::__copy_async();
    __syncthreads();

    // if (tid == 0) {
    //     printf("tid: %d\n", tid);
    //     DebugPrint(trg, KeTraits::kRows, KeTraits::kCols);
    // }
}
}  // namespace

namespace testing {

TEST(TestG2SCopy, Copy2DTile) {
    using Element = cutlass::half_t;

    static constexpr int kRows = 16;
    static constexpr int kCols = 8 * 4;

    static constexpr int kShmRows = kRows;
    static constexpr int kShmCols = kCols;

    // threads are arranged as 8 x 4 to perform 2D copy
    static const int kThreads = 32;

    int numel = kRows * kCols;
    thrust::host_vector<Element> h_A(numel);
    srand(42);
    for (int i = 0; i < h_A.size(); ++i) {
        // h_A[i] = __float2half(10 * (rand() / float(RAND_MAX)) - 5);
        h_A[i] = __float2half(i);
    }

    // copy data from host to device
    thrust::device_vector<Element> d_A = h_A;
    thrust::device_vector<Element> d_B(numel);
    thrust::fill(d_B.begin(), d_B.end(), static_cast<Element>(0.));

    int m = CeilDiv<kRows, kShmRows>;
    int n = CeilDiv<kCols, kShmCols>;
    LOG(INFO) << "blocks m: " << m << ", blocks n: " << n;

    dim3 dim_grid(m, n);
    dim3 dim_block(kThreads);

    using G2SCopyTraits = traits::G2S2DCopyTraits<Element, kRows, kCols,
                                                  kShmRows, kShmCols, kThreads>;

    using S2GCopyTraits = traits::S2G2DCopyTraits<Element, kRows, kCols,
                                                  kShmRows, kShmCols, kThreads>;

    LOG(INFO) << "threads arrangement: " << G2SCopyTraits::kThreadsRows << " x "
              << G2SCopyTraits::kThreadsCols;

    Copy<Element, G2SCopyTraits, S2GCopyTraits>
        <<<dim_grid, dim_block, kShmRows * kShmCols>>>(
            thrust::raw_pointer_cast(d_A.data()),
            thrust::raw_pointer_cast(d_B.data()));
    cudaDeviceSynchronize();

    // check correctness
    thrust::host_vector<Element> h_B(numel);
    h_B = d_B;

    CheckResult(reinterpret_cast<__half*>(thrust::raw_pointer_cast(h_A.data())),
                reinterpret_cast<__half*>(thrust::raw_pointer_cast(h_B.data())),
                numel);
}

}  // namespace testing
}  // namespace tiledcuda
