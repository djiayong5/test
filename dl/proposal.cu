/*
  Original version (21.8ms)
    1. [1ms] memcpy, D->H
      1-1. scores (75*2*36*46*float = 993.6KB)
      1-2. bbox (75*4*36*46*float = 1987.2KB)
    2. [15ms] all candidate enumeration & sort
    3. [0ms] memcpy, H->D, 6000*5*float = 120KB
    4. [3.3ms] nms kernel
    5. [1.8ms] memcpy, D->H, 6000*94*uint64 = 4512KB
    6. [0.7ms] roi retrieval (bitwise operations)
    7. [0ms] roi -> top

  Improved version (7ms)
    1. [0ms] no memcpy required
    2. [2.6ms] all candidate enumeration & sort
      2-1. [0.3ms] all candidate enumeration
      2-2. [0.6ms] memcpy, D->H, all candidates (75*36*46*5*float = 2484KB)
      2-3. [1.6ms] partial quick-sort
    3. [0ms] memcpy, H->D, 6000*5*float = 120KB
    4. [1.1ms] nms kernel
    5. [1.8ms] memcpy, D->H, 6000*94*uint64 = 4512KB
    6. [0.7ms] roi retrieval
    7. [0.8ms] roi -> top (300 memcpy, H->D, 4*float = 16B)

  TODO
    - GPU sort (improve 2-2, 2-3)
    - GPU roi retrieval (remove 5)
    - efficient roi -> top (improve 7)
*/

#include "layer.h"
#include <stdlib.h>
#include <math.h>

// --------------------------------------------------------------------------
// kernel code for NMS operation
//   iou: compute overlap between two boxes
//   nms_mask: given a set of boxes, compute overlap between all box pairs
//   nms: given a set of boxes, discard significantly-overlapped boxes
// --------------------------------------------------------------------------

// "IoU = intersection area / union area" of two boxes A, B
//   A, B: 4-dim array (x1, y1, x2, y2)
#ifdef GPU
__device__
#endif
inline real iou(const real* const A, const real* const B)
{
  // overlapped region (= box)
  const real x1 = MAX(A[0],  B[0]);
  const real y1 = MAX(A[1],  B[1]);
  const real x2 = MIN(A[2],  B[2]);
  const real y2 = MIN(A[3],  B[3]);

  // intersection area
  const real width = MAX(0.0f,  x2 - x1 + 1.0f);
  const real height = MAX(0.0f,  y2 - y1 + 1.0f);
  const real area = width * height;

  // area of A, B
  const real A_area = (A[2] - A[0] + 1.0f) * (A[3] - A[1] + 1.0f);
  const real B_area = (B[2] - B[0] + 1.0f) * (B[3] - B[1] + 1.0f);

  // IoU
  return area / (A_area + B_area - area);
}

// given box proposals, compute overlap between all box pairs
// (overlap = intersection area / union area)
// and then set mask-bit to 1 if a pair is significantly overlapped
//   num_boxes: number of box proposals given
//   boxes: "num_boxes x 5" array (x1, y1, x2, y2, score)
//   nms_thresh: threshold for determining "significant overlap"
//               if "intersection area / union area > nms_thresh",
//               two boxes are thought of as significantly overlapped
// the all-pair computation (num_boxes x num_boxes) is done by
// divide-and-conquer:
//   each GPU block (bj, bi) computes for "64 x 64" box pairs (j, i),
//     j = bj * 64 + { 0, 1, ..., 63 }
//     i = bi * 64 + { 0, 1, ..., 63 },
//   and each "1 x 64" results is saved into a 64-bit mask
//     mask: "num_boxes x num_blocks" array
//     for mask[j][bi], "di-th bit = 1" means:
//       box j is significantly overlapped with box i,
//       where i = bi * 64 + di
typedef unsigned long long uint64;
#define NMS_BLOCK_SIZE 64
#ifdef GPU
__global__
void nms_mask_gpu(const real* const boxes,
                  uint64* const mask,
                  const int num_boxes, const real nms_thresh)
{
  // block region
  //   j = j_start + { 0, ..., dj_end - 1 }
  //   i = i_start + { 0, ..., di_end - 1 }
  const int i_start = blockIdx.x * NMS_BLOCK_SIZE;
  const int di_end = MIN(num_boxes - i_start,  NMS_BLOCK_SIZE);
  const int j_start = blockIdx.y * NMS_BLOCK_SIZE;
  const int dj_end = MIN(num_boxes - j_start,  NMS_BLOCK_SIZE);

  // copy all i-th boxes to GPU cache
  //   i = i_start + { 0, ..., di_end - 1 }
  __shared__ real boxes_i[NMS_BLOCK_SIZE * 5];
  {
    const int di = threadIdx.x;
    if (di < di_end) {
      boxes_i[di * 5 + 0] = boxes[(i_start + di) * 5 + 0];
      boxes_i[di * 5 + 1] = boxes[(i_start + di) * 5 + 1];
      boxes_i[di * 5 + 2] = boxes[(i_start + di) * 5 + 2];
      boxes_i[di * 5 + 3] = boxes[(i_start + di) * 5 + 3];
      boxes_i[di * 5 + 4] = boxes[(i_start + di) * 5 + 4];
    }
  }
  __syncthreads();

  // given j = j_start + dj,
  //   check whether box i is significantly overlapped with box j
  //   (i.e., IoU(box j, box i) > threshold)
  //   for all i = i_start + { 0, ..., di_end - 1 } except for i == j
  {
    const int dj = threadIdx.x;
    if (dj < dj_end) {
      // box j
      const real* const box_j = boxes + (j_start + dj) * 5;

      // mask for significant overlap
      //   if IoU(box j, box i) > threshold,  di-th bit = 1
      uint64 mask_j = 0;

      // check for all i = i_start + { 0, ..., di_end - 1 }
      // except for i == j
      const int di_start = (i_start == j_start) ? (dj + 1) : 0;
      for (int di = di_start; di < di_end; ++di) {
        // box i
        const real* const box_i = boxes_i + di * 5;

        // if IoU(box j, box i) > threshold,  di-th bit = 1
        if (iou(box_j, box_i) > nms_thresh) {
          mask_j |= 1ULL << di;
        }
      }

      // mask: "num_boxes x num_blocks" array
      //   for mask[j][bi], "di-th bit = 1" means:
      //     box j is significantly overlapped with box i = i_start + di,
      //     where i_start = bi * block_size
      {
        const int num_blocks = DIV_THEN_CEIL(num_boxes,  NMS_BLOCK_SIZE);
        const int bi = blockIdx.x;
        mask[(j_start + dj) * num_blocks + bi] = mask_j;
      }
    } // endif dj < dj_end
  }
}
#else
void nms_mask_cpu(const real* const boxes,
                  uint64* const mask,
                  const int num_boxes, const real nms_thresh)
{
  // number of blocks along each dimension
  const int num_blocks = DIV_THEN_CEIL(num_boxes,  NMS_BLOCK_SIZE);

  // the whole 2-dim computations "num_boxes x num_boxes" is done by
  // sweeping all "64 x 64"-sized blocks
  for (int j_start = 0; j_start < num_boxes; j_start += NMS_BLOCK_SIZE) {
    for (int i_start = 0; i_start < num_boxes; i_start += NMS_BLOCK_SIZE) {
      // block region
      //   j = j_start + { 0, ..., dj_end - 1 }
      //   i = i_start + { 0, ..., di_end - 1 }
      const int di_end = MIN(num_boxes - i_start,  NMS_BLOCK_SIZE);
      const int dj_end = MIN(num_boxes - j_start,  NMS_BLOCK_SIZE);

      // check whether box i is significantly overlapped with box j
      // for all j = j_start + { 0, ..., dj_end - 1 },
      //         i = i_start + { 0, ..., di_end - 1 },
      // except for i == j
      for (int dj = 0; dj < dj_end; ++dj) {
        // box j & overlap mask
        const real* const box_j = boxes + (j_start + dj) * 5;
        uint64 mask_j = 0;

        // check for all i = i_start + { 0, ..., di_end - 1 }
        // except for i == j
        const int di_start = (i_start == j_start) ? (dj + 1) : 0;
        for (int di = di_start; di < di_end; ++di) {
          // box i
          const real* const box_i = boxes + (i_start + di) * 5;

          // if IoU(box j, box i) > threshold,  di-th bit = 1
          if (iou(box_j, box_i) > nms_thresh) {
            mask_j |= 1ULL << di;
          }
        }

        // mask: "num_boxes x num_blocks" array
        //   for mask[j][bi], "di-th bit = 1" means:
        //     box j is significantly overlapped with box i = i_start + di,
        //     where i_start = bi * block_size
        {
          const int bi = i_start / NMS_BLOCK_SIZE;
          mask[(j_start + dj) * num_blocks + bi] = mask_j;
        }
      } // endfor dj
    } // endfor j_start
  } // endfor i_start
}
#endif

// given box proposals (sorted in descending order of their scores),
// discard a box if it is significantly overlapped with
// one or more previous (= scored higher) boxes
//   num_boxes: number of box proposals given
//   boxes: "num_boxes x 5" array (x1, y1, x2, y2, score)
//          sorted in descending order of scores
//   num_out: number of remaining boxes
//   keep_out: "num_out x 1" array
//             indices of remaining boxes
//   nms_thresh: threshold for determining "significant overlap"
//               if "intersection area / union area > nms_thresh",
//               two boxes are thought of as significantly overlapped
void nms(const int num_boxes, const real* const boxes,
         int* const num_out, int* const keep_out,
         const real nms_thresh, const int max_num_out)
{
  const int num_blocks = DIV_THEN_CEIL(num_boxes,  NMS_BLOCK_SIZE);
  uint64* const mask
      = (uint64*)malloc(num_boxes * num_blocks * sizeof(uint64));

  #ifdef GPU
  {
    uint64* mask_dev;
    real* boxes_dev;
    const dim3 blocks(num_blocks, num_blocks);

    // GPU memory allocation & copy box data
    cudaMalloc(&boxes_dev, num_boxes * 5 * sizeof(real));
    cudaMemcpyAsync(boxes_dev, boxes, num_boxes * 5 * sizeof(real),
                    cudaMemcpyHostToDevice);
    cudaMalloc(&mask_dev, num_boxes * num_blocks * sizeof(uint64));

    // find all significantly-overlapped pairs of boxes
    nms_mask_gpu<<<blocks, NMS_BLOCK_SIZE>>>(
        boxes_dev,  mask_dev,  num_boxes,  nms_thresh);

    // copy mask data to main memory
    cudaMemcpyAsync(mask, mask_dev, sizeof(uint64) * num_boxes * num_blocks,
                    cudaMemcpyDeviceToHost);

    // GPU memory deallocation
    cudaFree(boxes_dev);
    cudaFree(mask_dev);
  }
  #else
  {
    // find all significantly-overlapped pairs of boxes
    nms_mask_cpu(boxes,  mask,  num_boxes,  nms_thresh);
  }
  #endif

  // discard i-th box if it is significantly overlapped with
  // one or more previous (= scored higher) boxes
  {
    int num_to_keep = 0;
    uint64* const remv = (uint64*)calloc(num_blocks, sizeof(uint64));

    for (int i = 0; i < num_boxes; ++i) {
      const int nblock = i / NMS_BLOCK_SIZE;
      const int inblock = i % NMS_BLOCK_SIZE;

      if (!(remv[nblock] & (1ULL << inblock))) {
        keep_out[num_to_keep++] = i;
        uint64* p = mask + i * num_blocks;
        for (int j = nblock; j < num_blocks; ++j) {
          remv[j] |= p[j];
        }

        if (num_to_keep == max_num_out) {
          break;
        }
      }
    }
    *num_out = num_to_keep;

    free(remv);
  }

  free(mask);
}



// --------------------------------------------------------------------------
// kernel code for proposal operation
//   transform_box: transform a box according to a given gradient
//   generate_anchors: generate anchor boxes of varying sizes and ratios
//   sort_box: sort a list of boxes in descending order of their scores
//   enumerate_proposals: generate all candidate boxes with their scores
// --------------------------------------------------------------------------

// transform a box according to a given gradient
//   box: (x1, y1, x2, y2)
//   gradient: dx, dy, d(log w), d(log h)
#ifdef GPU
__device__
#endif
int transform_box(real* const box,
                  const real dx, const real dy,
                  const real d_log_w, const real d_log_h,
                  const real img_W, const real img_H,
                  const real min_box_W, const real min_box_H)
{
  // width & height of box
  const real w = box[2] - box[0] + 1.0f;
  const real h = box[3] - box[1] + 1.0f;
  // center location of box
  const real ctr_x = box[0] + 0.5f * w;
  const real ctr_y = box[1] + 0.5f * h;

  // new center location according to gradient (dx, dy)
  const real pred_ctr_x = dx * w + ctr_x;
  const real pred_ctr_y = dy * h + ctr_y;
  // new width & height according to gradient d(log w), d(log h)
  const real pred_w = exp(d_log_w) * w;
  const real pred_h = exp(d_log_h) * h;

  // update upper-left corner location
  box[0] = pred_ctr_x - 0.5f * pred_w;
  box[1] = pred_ctr_y - 0.5f * pred_h;
  // update lower-right corner location
  box[2] = pred_ctr_x + 0.5f * pred_w;
  box[3] = pred_ctr_y + 0.5f * pred_h;

  // adjust new corner locations to be within the image region,
  box[0] = MAX(0.0f,  MIN(box[0],  img_W - 1.0f));
  box[1] = MAX(0.0f,  MIN(box[1],  img_H - 1.0f));
  box[2] = MAX(0.0f,  MIN(box[2],  img_W - 1.0f));
  box[3] = MAX(0.0f,  MIN(box[3],  img_H - 1.0f));

  // recompute new width & height
  const real box_w = box[2] - box[0] + 1.0f;
  const real box_h = box[3] - box[1] + 1.0f;

  // check if new box's size >= threshold
  return (box_w >= min_box_W) * (box_h >= min_box_H);
}

// given a base box, enumerate transformed boxes of varying sizes and ratios
//   option->base_size: base box's width & height (i.e., base box is square)
//   option->scales: "option->num_scales x 1" array
//                   varying scale factor for base box
//   option->ratios: "option->num_ratios x 1" array
//                   varying height-width ratio
//   option->num_concats: repeat count of anchor set generation
//                        (required for separated RPN)
//   anchors: "num_boxes x 4" array,  (x1, y1, x2, y2) for each box
//     num_boxes = total number of transformations
//         = option->num_scales * option->num_ratios * option->num_concats
#define MAX_NUM_RATIO_SCALE 10
void generate_anchors(real* const anchors,
                      const ProposalOption* const option)
{
  // base box's width & height & center location
  const real base_area = option->base_size * option->base_size;
  const real ctr = 0.5f * (option->base_size - 1.0f);

  // transformed width & height for given ratios
  real wr[MAX_NUM_RATIO_SCALE];
  real hr[MAX_NUM_RATIO_SCALE];
  for (int i = 0; i < option->num_ratios; ++i) {
    wr[i] = ROUND(sqrt(base_area / option->ratios[i]));
    hr[i] = ROUND(wr[i] * option->ratios[i]);
  }

  // enumerate all transformed boxes
  {
    real* p_anchors = anchors;
    for (int c = 0; c < option->num_concats; ++c) {
      for (int i = 0; i < option->num_ratios; ++i) {
        for (int j = 0; j < option->num_scales; ++j) {
          // transformed width & height for given ratios & scales
          const real ws = 0.5f * (wr[i] * option->scales[j] - 1.0f);
          const real hs = 0.5f * (hr[i] * option->scales[j] - 1.0f);
          // (x1, y1, x2, y2) for transformed box
          p_anchors[0] = ctr - ws;
          p_anchors[1] = ctr - hs;
          p_anchors[2] = ctr + ws;
          p_anchors[3] = ctr + hs;
          p_anchors += 4;
        } // endfor j
      } // endfor i
    } // endfor c
  }
}

// quick-sort a list of boxes in descending order of their scores
//   if num_top <= end,  only top-k results are guaranteed to be sorted
//   (for efficient computation)
void sort_box(real* const list, const int start, const int end,
              const int num_top)
{
  const real pivot_score = list[start * 5 + 4];
  int left = start + 1, right = end;
  real temp[5];
  while (left <= right) {
    while (left <= end && list[left * 5 + 4] >= pivot_score) ++left;
    while (right > start && list[right * 5 + 4] <= pivot_score) --right;
    if (left <= right) {
      for (int i = 0; i < 5; ++i) {
        temp[i] = list[left * 5 + i];
      }
      for (int i = 0; i < 5; ++i) {
        list[left * 5 + i] = list[right * 5 + i];
      }
      for (int i = 0; i < 5; ++i) {
        list[right * 5 + i] = temp[i];
      }
      ++left;
      --right;
    }
  }

  if (right > start) {
    for (int i = 0; i < 5; ++i) {
      temp[i] = list[start * 5 + i];
    }
    for (int i = 0; i < 5; ++i) {
      list[start * 5 + i] = list[right * 5 + i];
    }
    for (int i = 0; i < 5; ++i) {
      list[right * 5 + i] = temp[i];
    }
  }

  if (start < right - 1) {
    sort_box(list, start, right - 1, num_top);
  }
  if (right + 1 < num_top && right + 1 < end) {
    sort_box(list, right + 1, end, num_top);
  }
}

// enumerate_proposals: generate all candidate boxes with their scores
//   bottom: 1 x num_anchors x H x W tensor
//     bottom[0, k, h, w] = foreground score of anchor k at node (h, w)
//   d_anchor: num_anchors x 4 x H x W tensor
//     d_anchor[k, :, h, w] = gradient (dx, dy, d(log w), d(log h))
//                            of anchor k at center location (h, w)
//   num_anchors: number of anchors  (= # concats * # scales * # ratios)
//   anchors: num_anchors * 4 array,  (x1, y1, x2, y2) for each anchor
//   img_H, img_W: scaled image height & width
//   min_box_H, min_box_W: minimum box height & width
//   feat_stride: scaled image height (width) / bottom height (width)
//   proposals: num_proposals * 5 array
//     num_proposals = num_anchors * H * W
//     (x1, y1, x2, y2, score) for each proposal
#ifdef GPU
__global__
void enumerate_proposals_gpu(const real* const bottom4d,
                             const real* const d_anchor4d,
                             const real* const anchors,
                             const int num_anchors,
                             const int bottom_H, const int bottom_W,
                             const real img_H, const real img_W,
                             const real min_box_H, const real min_box_W,
                             const int feat_stride,
                             real* const proposals)
{
  const int bottom_area = bottom_H * bottom_W;
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < num_anchors * bottom_area) {
    const int h = index / num_anchors / bottom_W;
    const int w = (index / num_anchors) % bottom_W;
    const int k = index % num_anchors;
    const real x = w * feat_stride;
    const real y = h * feat_stride;
    const real* p_box = d_anchor4d + h * bottom_W + w;
    const real* p_score = bottom4d + h * bottom_W + w;

    const real dx = p_box[(k * 4 + 0) * bottom_area];
    const real dy = p_box[(k * 4 + 1) * bottom_area];
    const real d_log_w = p_box[(k * 4 + 2) * bottom_area];
    const real d_log_h = p_box[(k * 4 + 3) * bottom_area];

    proposals[index * 5 + 0] = x + anchors[k * 4 + 0];
    proposals[index * 5 + 1] = y + anchors[k * 4 + 1];
    proposals[index * 5 + 2] = x + anchors[k * 4 + 2];
    proposals[index * 5 + 3] = y + anchors[k * 4 + 3];

    proposals[index * 5 + 4]
        = transform_box(&proposals[index * 5],
                        dx, dy, d_log_w, d_log_h,
                        img_W, img_H, min_box_W, min_box_H)
          * p_score[k * bottom_area];
  }
}
#else
void enumerate_proposals_cpu(const real* const bottom4d,
                             const real* const d_anchor4d,
                             const real* const anchors,
                             const int num_anchors,
                             const int bottom_H, const int bottom_W,
                             const real img_H, const real img_W,
                             const real min_box_H, const real min_box_W,
                             const int feat_stride,
                             real* const proposals)
{
  const int bottom_area = bottom_H * bottom_W;
  for (int h = 0; h < bottom_H; ++h) {
    for (int w = 0; w < bottom_W; ++w) {
      const real x = w * feat_stride;
      const real y = h * feat_stride;
      const real* p_box = d_anchor4d + h * bottom_W + w;
      const real* p_score = bottom4d + h * bottom_W + w;
      for (int k = 0; k < num_anchors; ++k) {
        const real dx = p_box[(k * 4 + 0) * bottom_area];
        const real dy = p_box[(k * 4 + 1) * bottom_area];
        const real d_log_w = p_box[(k * 4 + 2) * bottom_area];
        const real d_log_h = p_box[(k * 4 + 3) * bottom_area];

        const int index = (h * bottom_W + w) * num_anchors + k;
        proposals[index * 5 + 0] = x + anchors[k * 4 + 0];
        proposals[index * 5 + 1] = y + anchors[k * 4 + 1];
        proposals[index * 5 + 2] = x + anchors[k * 4 + 2];
        proposals[index * 5 + 3] = y + anchors[k * 4 + 3];

        proposals[index * 5 + 4]
            = transform_box(&proposals[index * 5],
                            dx, dy, d_log_w, d_log_h,
                            img_W, img_H, min_box_W, min_box_H)
              * p_score[k * bottom_area];
      } // endfor k
    } // endfor w
  } // endfor h
}
#endif



// --------------------------------------------------------------------------
// layer operator code
//   proposal_forward
// --------------------------------------------------------------------------

// proposal: bottom -> top
//   bottom: 2 x num_anchors x H x W tensor
//     bottom[0, k, h, w] = background score of anchor k at node (h, w)
//     bottom[1, k, h, w] = foreground score of anchor k at node (h, w)
//   d_anchor: num_anchors x 4 x H x W tensor
//     d_anchor[k, :, h, w] = gradient (dx, dy, d(log w), d(log h))
//                            of anchor k at center location (h, w)
//   img_info: 4 x 1 tensor,  (img_H, img_W, min_box_W, min_box_H)
//     img_H, img_W: scaled image height & width
//     min_box_W: minimum box width in raw image
//     min_box_H: minimum box height in raw image
//   top: num_RoIs x 4 tensor,  (x1, y1, x2, y2) of each RoI
//   anchors: num_anchors * 4 array,  (x1, y1, x2, y2) for each anchor
void proposal_forward(const Tensor* const bottom4d,
                      const Tensor* const d_anchor4d,
                      const Tensor* const img_info1d,
                      Tensor* const top2d,
                      const real* const anchors,
                      const ProposalOption* const option)
{

  const int num_anchors
      = option->num_concats * option->num_ratios * option->num_scales;

  int* const keep = (int*)malloc(option->post_nms_topn * sizeof(int));
  real* const proposals = (real*)malloc(num_anchors * 80*80 * 5 * sizeof(real));
  #ifdef GPU
  real* proposals_dev;
  cudaMalloc(&proposals_dev, num_anchors * 80*80 * 5 * sizeof(real));
  #endif

  // do forward-pass for each item in the batch
  const real* p_bottom_item = bottom4d->data;
  const real* p_d_anchor_item = d_anchor4d->data;
  const real* p_img_info = img_info1d->data;
  real* p_top_item = top2d->data;
  for (int n = 0; n < bottom4d->num_items; ++n) {
    // bottom shape: 2 x num_anchors x H x W
    const int bottom_H = bottom4d->shape[n][2];
    const int bottom_W = bottom4d->shape[n][3];
    const int bottom_area = bottom_H * bottom_W;
    // input image height & width
    const real img_H = p_img_info[0];
    const real img_W = p_img_info[1];
    // minimum box width & height
    const real min_box_W = option->min_size * p_img_info[2];
    const real min_box_H = option->min_size * p_img_info[3];

    // enumerate all proposals
    //   num_proposals = num_anchors * H * W
    //   (x1, y1, x2, y2, score) for each proposal
    // NOTE: for bottom, only foreground scores are passed
    {
    #ifdef GPU
      const int num_threads = num_anchors * bottom_area;
      const int threads_per_block = 512;
      const int num_blocks = DIV_THEN_CEIL(num_threads,  threads_per_block);
      enumerate_proposals_gpu<<<num_blocks, threads_per_block>>>(
          p_bottom_item + num_anchors * bottom_area,
          p_d_anchor_item,  anchors,  num_anchors,
          bottom_H,  bottom_W,  img_H,  img_W,  min_box_H,  min_box_W,
          option->feat_stride,
          proposals_dev);
    #else
      enumerate_proposals_cpu(
          p_bottom_item + num_anchors * bottom_area,
          p_d_anchor_item,  anchors,  num_anchors,
          bottom_H,  bottom_W,  img_H,  img_W,  min_box_H,  min_box_W,
          option->feat_stride,
          proposals);
    #endif
    }

    // choose candidates according to scores
    // TODO: copy proposals to GPU memory directly
    {
      const int num_proposals = num_anchors * bottom_area;
    #ifdef GPU
      cudaMemcpyAsync(proposals, proposals_dev,
                      num_proposals * 5 * sizeof(real),
                      cudaMemcpyDeviceToHost);
    #endif
      sort_box(proposals, 0, num_proposals - 1, option->pre_nms_topn);
    }

    // NMS & RoI retrieval
    {
      const int num_proposals
          = MIN(num_anchors * bottom_area,  option->pre_nms_topn);
      int num_rois = 0;
      nms(num_proposals,  proposals,  &num_rois,  keep,
          option->nms_thresh,  option->post_nms_topn);

    #ifdef GPU
      for (int i = 0; i < num_rois; ++i) {
        cudaMemcpyAsync(p_top_item + i * 4, proposals + keep[i] * 5,
                        4 * sizeof(real),
                        cudaMemcpyHostToDevice);
      }
    #else
      for (int i = 0; i < num_rois; ++i) {
        p_top_item[i * 4 + 0] = proposals[keep[i] * 5 + 0];
        p_top_item[i * 4 + 1] = proposals[keep[i] * 5 + 1];
        p_top_item[i * 4 + 2] = proposals[keep[i] * 5 + 2];
        p_top_item[i * 4 + 3] = proposals[keep[i] * 5 + 3];
      }
    #endif

      // set top shape: num_rois x 4,  (x1, y1, x2, y2) for each RoI
      top2d->shape[n][0] = num_rois;
      top2d->shape[n][1] = 4;
    }

    // locate next item
    {
      const int bottom_size = 2 * num_anchors * bottom_area;
      const int d_anchor_size = 4 * num_anchors * bottom_area;
      const int img_info_size = 4;
      const int top_size = 4 * top2d->shape[n][0];
      p_bottom_item += bottom_size;
      p_d_anchor_item += d_anchor_size;
      p_img_info += img_info_size;
      p_top_item += top_size;
    }
  } // endfor batch

  top2d->ndim = 2;
  top2d->num_items = bottom4d->num_items;

  #ifdef GPU
  cudaFree(proposals_dev);
  #endif
  free(proposals);
  free(keep);
}



// --------------------------------------------------------------------------
// layer shape calculator code
// --------------------------------------------------------------------------
void proposal_shape(const Tensor* const bottom4d,
                    Tensor* const top2d,
                    const ProposalOption* const option)
{
  // calculate shape for each item in the batch
  top2d->ndim = 2;
  top2d->num_items = bottom4d->num_items;
  for (int n = 0; n < bottom4d->num_items; ++n) {
    // top shape <= post_nms_topn x 4
    //   exact row size will be determined after forward-pass
    top2d->shape[n][0] = option->post_nms_topn;
    top2d->shape[n][1] = 4;
  }
}



// --------------------------------------------------------------------------
// test code
// --------------------------------------------------------------------------

#ifdef TEST
#include <stdio.h>

int main(int argc, char *argv[])
{
  // variable declaration & memory allocation
  Tensor score, d_anchor, img_info, roi, roi_true;
  real *score_data = NULL, *d_anchor_data = NULL, *img_info_data = NULL;
  real *roi_data, *roi_true_data;
  real scales[5] = {3, 6, 9, 16, 32};
  real ratios[5] = {0.5, 0.666, 1.0, 1.5, 2.0};
  real *anchors, *p_anchors;
  int num_anchors;
  ProposalOption option;

  // set option
  {
    option.scales = &scales[0];
    option.ratios = &ratios[0];
    option.num_scales = 5;
    option.num_ratios = 5;
    option.num_concats = 3;
    option.base_size = 16;
    option.feat_stride = 16;
    option.min_size = 16;
    option.pre_nms_topn = 6000;
    option.post_nms_topn = 300;
    option.nms_thresh = 0.7;
  }

  // generate anchors
  {
    num_anchors = option.num_scales * option.num_ratios * option.num_concats;
    // 4 real variables for each anchor: (x1, y1, x2, y2)
    anchors = (real*)malloc(num_anchors * 4 * sizeof(real));
    generate_anchors(anchors, &option);
  }

  // load data
  {
    int ndim;
    int shape[g_max_ndim];
    int total_size;

    // score: 2 x num_anchors x H x W tensor
    score_data
        = load_data("../data/temp/proposal_bottom0.bin", &ndim, shape);
    score.num_items = shape[0];
    score.ndim = 4;
    total_size = 0;
    for (int n = 0; n < score.num_items; ++n) {
      score.shape[n][0] = 2;
      score.shape[n][1] = num_anchors;
      score.shape[n][2] = shape[2];
      score.shape[n][3] = shape[3];
      score.start[n] = total_size;
      total_size += 2 * num_anchors * shape[2] * shape[3];
    }

    // d_anchor: num_anchors x 4 x H x W tensor
    d_anchor_data
        = load_data("../data/temp/proposal_bottom1.bin", &ndim, shape);
    d_anchor.num_items = shape[0];
    d_anchor.ndim = 4;
    total_size = 0;
    for (int n = 0; n < d_anchor.num_items; ++n) {
      d_anchor.shape[n][0] = num_anchors;
      d_anchor.shape[n][1] = 4;
      d_anchor.shape[n][2] = shape[2];
      d_anchor.shape[n][3] = shape[3];
      d_anchor.start[n] = total_size;
      total_size += num_anchors * 4 * shape[2] * shape[3];
    }

    // img_info: 4 x 1 tensor
    img_info_data
        = load_data("../data/temp/proposal_bottom2.bin", &ndim, shape);
    img_info.num_items = 1;
    img_info.ndim = 1;
    img_info.shape[0][0] = shape[0];

    // roi_true: num_rois x 4 tensor
    roi_true_data
        = load_data("../data/temp/proposal_top0.bin", &ndim, shape);
    {
      const int num_rois = shape[0];
      int num_items = 0;
      for (int i = 0; i < num_rois; ++i) {
        const int n = (int)ROUND(roi_true_data[i * 5 + 0]);
        const real x1 = roi_true_data[i * 5 + 1];
        const real y1 = roi_true_data[i * 5 + 2];
        const real x2 = roi_true_data[i * 5 + 3];
        const real y2 = roi_true_data[i * 5 + 4];
        ++roi_true.shape[n][0];
        roi_true_data[i * 4 + 0] = x1;
        roi_true_data[i * 4 + 1] = y1;
        roi_true_data[i * 4 + 2] = x2;
        roi_true_data[i * 4 + 3] = y2;
        num_items = MAX(num_items,  n);
      }
      roi_true.num_items = num_items + 1;
    }
    roi_true.ndim = 2;
    for (int n = 0; n < roi_true.num_items; ++n) {
      roi_true.shape[n][1] = 4;
    }

    proposal_shape(&score, &roi, &option);
    roi_data = (real*)malloc(flatten_size(&roi) * sizeof(real));
  }

  // CUDA initialization
  #ifdef GPU
  {
    printf("set device\n");
    cudaSetDevice(0);
  }
  #endif

  // bind loaded data to corresponding tensors
  #ifdef GPU
  {
    const int score_size = flatten_size(&score);
    const int d_anchor_size = flatten_size(&d_anchor);
    const int roi_size = flatten_size(&roi);

    printf("gpu malloc\n");
    cudaMalloc(&score.data, score_size * sizeof(real));
    cudaMalloc(&d_anchor.data, d_anchor_size * sizeof(real));
    cudaMalloc(&p_anchors, num_anchors * 4 * sizeof(real));
    cudaMalloc(&roi.data, roi_size * sizeof(real));

    printf("memcpy: cpu -> gpu\n");
    cudaMemcpyAsync(score.data, score_data,
                    score_size * sizeof(real),
                    cudaMemcpyHostToDevice);
    cudaMemcpyAsync(d_anchor.data, d_anchor_data,
                    d_anchor_size * sizeof(real),
                    cudaMemcpyHostToDevice);
    cudaMemcpyAsync(p_anchors, anchors,
                    num_anchors * 4 * sizeof(real),
                    cudaMemcpyHostToDevice);

    img_info.data = img_info_data;
  }
  #else
  {
    score.data = score_data;
    d_anchor.data = d_anchor_data;
    p_anchors = anchors;
    img_info.data = img_info_data;
    roi.data = roi_data;
  }
  #endif

  // do forward operation
  {
    printf("do forward\n");
    proposal_forward(&score, &d_anchor, &img_info, &roi, p_anchors, &option);
  }

  // copy GPU data to main memory
  #ifdef GPU
  {
    const int roi_size = flatten_size(&roi);

    printf("memcpy: cpu <- gpu\n");
    cudaMemcpyAsync(roi_data, roi.data, roi_size * sizeof(real),
                    cudaMemcpyDeviceToHost);
  }
  #endif

  // verify results
  {
    const int roi_size = flatten_size(&roi);
    const int roi_true_size = flatten_size(&roi_true);
    int i = 0, i_true = 0;

    printf("verification\n");

    for (; i < roi_size && i_true < roi_true_size; i += 4, i_true += 4) {
      real diff = 0.0f;
      for (int di = 0; di < 4; ++di) {
        diff += ABS(roi_data[i + di] - roi_true_data[i_true + di]) /
                (1e-10f + MIN(roi_data[i + di], roi_true_data[i_true + di]));
      }
      if (diff > 1e-3f) {
        real diff1 = 0.0f;
        for (int di = 0; i_true + 4 + di < roi_true_size && di < 4; ++di) {
          diff1 += ABS(roi_data[i + di] - roi_true_data[i_true + 4 + di]) /
            (1e-10f + MIN(roi_data[i + di], roi_true_data[i_true + 4 + di]));
        }
        if (diff1 < 1e-3f) {
          printf("[False Negative] RoI_true[%d]: %.2f %.2f %.2f %.2f\n",
                 i_true / 4,
                 roi_true_data[i_true + 0], roi_true_data[i_true + 1],
                 roi_true_data[i_true + 2], roi_true_data[i_true + 3]);
          i_true += 4;
          continue;
        }
        real diff2 = 0.0f;
        for (int di = 0; i + 4 + di < roi_size && di < 4; ++di) {
          diff1 += ABS(roi_data[i + 4 + di] - roi_true_data[i_true + di]) /
            (1e-10f + MIN(roi_data[i + 4 + di], roi_true_data[i_true + di]));
        }
        if (diff2 < 1e-3f) {
          printf("[False Positive] RoI[%d]: %.2f %.2f %.2f %.2f\n",
                 i / 4, roi_data[i + 0], roi_data[i + 1],
                 roi_data[i + 2], roi_data[i + 3]);
          i += 4;
          continue;
        }
        printf("RoI[%d]: %.2f %.2f %.2f %.2f  ",
               i / 4, roi_data[i + 0], roi_data[i + 1],
               roi_data[i + 2], roi_data[i + 3]);
        printf("RoI_true[%d]: %.2f %.2f %.2f %.2f\n",
               i_true / 4,
               roi_true_data[i_true + 0], roi_true_data[i_true + 1],
               roi_true_data[i_true + 2], roi_true_data[i_true + 3]);
      }
    }
    for (; i < roi_size; i += 4) {
      printf("[False Positive] RoI[%d]: %.2f %.2f %.2f %.2f\n",
             i / 4, roi_data[i + 0], roi_data[i + 1],
             roi_data[i + 2], roi_data[i + 3]);
    }
    for (; i_true < roi_true_size; i_true += 4) {
      printf("[False Negative] RoI_true[%d]: %.2f %.2f %.2f %.2f\n",
             i_true / 4,
             roi_true_data[i_true + 0], roi_true_data[i_true + 1],
             roi_true_data[i_true + 2], roi_true_data[i_true + 3]);
    }
  }

  // memory deallocation
  {
    free(anchors);
    free(score_data);
    free(d_anchor_data);
    free(img_info_data);
    free(roi_data);
    free(roi_true_data);
  }
  #ifdef GPU
  {
    printf("gpu free\n");
    cudaFree(score.data);
    cudaFree(d_anchor.data);
    cudaFree(p_anchors);
    cudaFree(roi.data);
  }
  #endif

  return 0;
}
#endif // endifdef TEST
