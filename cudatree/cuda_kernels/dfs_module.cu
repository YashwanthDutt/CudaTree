#include <stdio.h>
#include <math.h>
#include <stdint.h>
#include <assert.h>

#define THREADS_PER_BLOCK %d
#define RESHUFFLE_THREADS_PER_BLOCK %d
#define MAX_NUM_LABELS %d
#define SAMPLE_DATA_TYPE %s
#define LABEL_DATA_TYPE %s
#define COUNT_DATA_TYPE %s
#define IDX_DATA_TYPE %s
#define MAX_BLOCK_PER_FEATURE %d
#define DEBUG %d

#include "common_func.cu"

#define WARP_SIZE 32
#define WARP_MASK 0x1f

texture<char, 1> tex_mark;
__device__ __constant__ uint32_t stride;

__global__ void scan_gini_large(
                        IDX_DATA_TYPE *sorted_indices,
                        LABEL_DATA_TYPE *labels, 
                        COUNT_DATA_TYPE *label_total_2d,
                        uint16_t *subset_indices,
                        int n_range,
                        int n_samples
                        //int stride
                        ){
   
  /* 
    Fill the label_total_2d array for each feature and each range of that feature. 
    Inputs: 
      - sorted_indices : sorted indices.
      - labels : labels.
      - subset_indices : randomly generated featureindices. determine which feature we should count. 
      - n_range : the range of each block is responsible for.
      - n_samples : number of samples for this node.
      - stride : the stride of sorted_indices.
  
    Outputs:
      - label_total_2d : the label total for each range.
  */
  __shared__ int shared_count[MAX_NUM_LABELS];
  uint32_t offset = blockIdx.x * MAX_NUM_LABELS * (MAX_BLOCK_PER_FEATURE + 1) + (blockIdx.y + 1) * MAX_NUM_LABELS;
  uint32_t subset_offset = subset_indices[blockIdx.x] * stride;
  
  IDX_DATA_TYPE start_pos = blockIdx.y * n_range;
  IDX_DATA_TYPE stop_pos = (start_pos + n_range < n_samples)? start_pos + n_range: n_samples;

  for(uint16_t i = threadIdx.x; i < MAX_NUM_LABELS; i += blockDim.x)
    shared_count[i] = 0;
  
  __syncthreads();

  for(IDX_DATA_TYPE i = start_pos; i < stop_pos; i += blockDim.x){
    IDX_DATA_TYPE idx = i + threadIdx.x;
    if(idx < stop_pos)
      atomicAdd(shared_count + labels[sorted_indices[subset_offset + idx]], 1);
  }

  #if DEBUG == 1
  __syncthreads();
  if(threadIdx.x == 0){
    int sum = 0;
    for(int i = 0; i < MAX_NUM_LABELS; ++i)
      sum += shared_count[i];
    
    assert(sum == stop_pos - start_pos);
  }
  #endif

  __syncthreads();

  for(uint16_t i = threadIdx.x; i < MAX_NUM_LABELS; i += blockDim.x)
    label_total_2d[offset + i] = shared_count[i];
}

__global__ void scan_reduce(
                        COUNT_DATA_TYPE *label_total_2d,
                        int n_block
                        ){
  /* 
    Do a prefix scan to add each range of label_total_2d generated by previous scan_total_2d kernel.
    Inputs: 
      - label_total_2d : the label_total_2d generated by scan_total_2d kernel.
      - n_block : how many blocks(ranges). For examples, we can divide 10000 samples to 40 blocks, 
                  each block has 250 samples. 
    Outputs:
      - label_total_2d : after a prefix scan add.
  */

  uint32_t offset = blockIdx.x * (MAX_BLOCK_PER_FEATURE + 1) * MAX_NUM_LABELS;
  
  for(uint16_t i = 2; i <= n_block; ++i){
    
    uint32_t last_off = (i - 1) * MAX_NUM_LABELS;
    uint32_t this_off = i * MAX_NUM_LABELS;

    for(uint16_t t = threadIdx.x; t < MAX_NUM_LABELS; t += blockDim.x)
      label_total_2d[offset + this_off + t] += label_total_2d[offset + last_off + t];
  } 
}


__global__ void reduce(
                      float *impurity_2d,
                      float *impurity_left,
                      float *impurity_right,
                      IDX_DATA_TYPE *split_2d,
                      IDX_DATA_TYPE *split_1d, 
                      int n_block
                      ){
  /* 
    Reduce the 2d impurity into 1d. Find best gini score and split index for each feature.
    The previous kernel produces the best gini score and best split for each range of the feature.
    Inputs: 
      - impurity_2d : the best gini score for each range of feature produced by previous kernel.
      - split_2d : the best split index of each range produced by previous kernel.
      - n_block : number of ranges.
    
    Outputs:
      - impurity_left : the best gini score on left part for the feature.
      - impurity_right : the best gini score on right part for the feature.
      - split_1d : the best split index of the who feature.
  */

  __shared__ float shared_imp[MAX_BLOCK_PER_FEATURE * 2];
  uint32_t imp_offset = blockIdx.x * MAX_BLOCK_PER_FEATURE * 2;
  uint32_t split_offset = blockIdx.x * MAX_BLOCK_PER_FEATURE;
  
  for(uint16_t t= threadIdx.x; t < n_block * 2; t += blockDim.x)
    shared_imp[t] = impurity_2d[imp_offset + t];
  
  __syncthreads();
  
  if(threadIdx.x == 0){
    float min_left = 2.0;
    float min_right = 2.0;
    uint16_t min_idx = 0;
    for(uint16_t i = 0; i < n_block; ++i)
      if(min_left + min_right > shared_imp[i * 2] + shared_imp[2 * i + 1]){
        min_left = shared_imp[i * 2];
        min_right = shared_imp[2 * i + 1];
        min_idx = i;
      }
    impurity_left[blockIdx.x] = min_left;
    impurity_right[blockIdx.x] = min_right;
    split_1d[blockIdx.x] = split_2d[split_offset + min_idx];
  }
}



__global__ void find_min_imp(
                          float* imp_left,
                          float* imp_right,
                          COUNT_DATA_TYPE *min_split,
                          int max_features
                          ){
  __shared__ uint16_t min_tid;
  __shared__ float shared_imp_total[32];
  float reg_imp_left;
  float reg_imp_right;
  COUNT_DATA_TYPE reg_min_idx = 0;
  int reg_min_feature_idx = 0;

  reg_imp_left = 2.0;
  reg_imp_right = 2.0;

  for(uint16_t i = threadIdx.x; i < max_features; i += blockDim.x){
    float left = imp_left[i]; 
    float right = imp_right[i]; 
    COUNT_DATA_TYPE idx = min_split[i];

    if(left + right < reg_imp_left + reg_imp_right){
      reg_imp_left = left;
      reg_imp_right = right;
      reg_min_idx = idx;
      reg_min_feature_idx = i;
    }
  }
  

  shared_imp_total[threadIdx.x] = reg_imp_left + reg_imp_right;
  
  __syncthreads();
  
  if(threadIdx.x == 0){
    float min_imp = 4.0;
    for(uint16_t i = 0; i < blockDim.x; ++i)
      if(shared_imp_total[i] < min_imp){
        min_tid = i;
        min_imp = shared_imp_total[i];
      }
  }
  __syncthreads();
  
  if(threadIdx.x == min_tid){
    imp_left[0] = reg_imp_left;
    imp_left[1] = reg_imp_right;
    imp_left[2] = reg_min_idx;
    imp_left[3] = reg_min_feature_idx;
  }
}

__global__ void fill_table(IDX_DATA_TYPE *sorted_indices,
                          int n_samples,
                          int split_idx,
                          uint8_t *mark_table
                          //int stride
                          ){
    for(int i = threadIdx.x; i < n_samples; i += blockDim.x)
      if(i <= split_idx)
        mark_table[sorted_indices[i]] = 1;
      else 
        mark_table[sorted_indices[i]] = 0;
}


__global__ void scan_reshuffle(
                          IDX_DATA_TYPE* sorted_indices,
                          IDX_DATA_TYPE* sorted_indices_out,
                          int n_samples,
                          int split_idx
                          //int stride
                          ){  
  uint32_t indices_offset = blockIdx.x * stride;
  IDX_DATA_TYPE reg_pos = 0;
  uint32_t out_pos;
  uint32_t right_pos = indices_offset + split_idx + 1;
  uint8_t side;
  IDX_DATA_TYPE n;

#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 300
  uint16_t lane_id = threadIdx.x & WARP_MASK;
  uint16_t warp_id = threadIdx.x / WARP_SIZE;
  __shared__ IDX_DATA_TYPE shared_pos_table[RESHUFFLE_THREADS_PER_BLOCK / WARP_SIZE];
#else
  __shared__ IDX_DATA_TYPE shared_pos_table[RESHUFFLE_THREADS_PER_BLOCK];
#endif
  
  __shared__ IDX_DATA_TYPE last_sum;
  
  if(threadIdx.x == 0)
    last_sum = 0;
  
  for(IDX_DATA_TYPE i = threadIdx.x; i < n_samples; i += blockDim.x){
    side = tex1Dfetch(tex_mark, sorted_indices[indices_offset + i]);
    reg_pos = side;

#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 300
  
    for(uint16_t s = 1; s < WARP_SIZE; s *= 2){
      n = __shfl_up((int)reg_pos, s);
      if(lane_id >= s)
        reg_pos += n;
    }

    if(lane_id == WARP_SIZE - 1)
      shared_pos_table[warp_id] = reg_pos;
   
    __syncthreads();
   
    if(threadIdx.x == 0)
      for(uint16_t l = 1; l < blockDim.x / WARP_SIZE - 1; ++l)
        shared_pos_table[l] += shared_pos_table[l-1];

    __syncthreads();
    
    if(warp_id > 0)
      reg_pos += shared_pos_table[warp_id - 1];
    
    reg_pos += last_sum; 

#else
    
    shared_pos_table[threadIdx.x] = reg_pos;
    __syncthreads();
     
    for(uint16_t s = 1; s < blockDim.x; s *= 2){
      if(threadIdx.x >= s){
        n = shared_pos_table[threadIdx.x - s];
      }
      else 
        n = 0;

      __syncthreads();
      shared_pos_table[threadIdx.x] += n;
      __syncthreads();
    }

    reg_pos = shared_pos_table[threadIdx.x] + last_sum;  
#endif

    out_pos = (side == 1)? indices_offset + reg_pos - 1 : right_pos + i - reg_pos ;
    sorted_indices_out[out_pos] = sorted_indices[indices_offset + i];  
    
    __syncthreads();
    
    if(threadIdx.x == blockDim.x - 1)
      last_sum = reg_pos; 
  }
}


__global__ void compute_2d(IDX_DATA_TYPE *sorted_indices,
                        SAMPLE_DATA_TYPE *samples, 
                        LABEL_DATA_TYPE *labels,
                        float *impurity_2d, 
                        COUNT_DATA_TYPE *label_total_2d,
                        COUNT_DATA_TYPE *split, 
                        uint16_t *subset_indices,
                        int n_range,
                        int n_samples 
                        //int stride
                        ){
  /* 
    Compute and find minimum gini score for each range of each random generated feature.
    Inputs: 
      - sorte_indices : sorted indices.
      - samples : samples.
      - labels : labels.
      - label_total_2d : label_total for each range of each feature generated by scan_reduce kernel.
      - subset_indices : random generated a subset of features.
      - n_range : we divide the samples into seperate ranges, the number of samples per range.
      - n_samples : number of samples this internal node has.
      - stride : the stride for sorted indices and samples.
    
    Outputs:
      - impurity_2d : the minimum impurity score for each range of each feature.
      - split : the split index which produces the minimum gini score.
  */ 
  uint16_t step = blockDim.x - 1;

  uint32_t offset = subset_indices[blockIdx.x] * stride;
  float reg_imp_right = 2.0;
  float reg_imp_left = 2.0;
  COUNT_DATA_TYPE reg_min_split = 0;

  __shared__ float shared_count[MAX_NUM_LABELS];
  __shared__ LABEL_DATA_TYPE shared_labels[THREADS_PER_BLOCK];
  __shared__ float shared_count_total[MAX_NUM_LABELS];
  __shared__ SAMPLE_DATA_TYPE shared_samples[THREADS_PER_BLOCK];
  
  uint32_t cur_offset = blockIdx.x * (MAX_BLOCK_PER_FEATURE + 1) * MAX_NUM_LABELS + blockIdx.y * MAX_NUM_LABELS;
  uint32_t last_offset = int(ceil(float(n_samples) / n_range)) * MAX_NUM_LABELS;

  for(uint16_t i = threadIdx.x; i < MAX_NUM_LABELS; i += blockDim.x){   
      shared_count[i] = label_total_2d[cur_offset + i];
      shared_count_total[i] = label_total_2d[last_offset + i];
  }
  
  IDX_DATA_TYPE stop_pos = ((blockIdx.y + 1) * n_range  < n_samples - 1)? (blockIdx.y + 1) * n_range : n_samples - 1;

  for(IDX_DATA_TYPE i = blockIdx.y * n_range; i < stop_pos; i += step){ 
    IDX_DATA_TYPE index = i + threadIdx.x;
    IDX_DATA_TYPE idx;

    if(index < stop_pos + 1){
      idx = sorted_indices[offset + index];
      shared_labels[threadIdx.x] = labels[idx]; 
      shared_samples[threadIdx.x] = samples[offset + idx];
    }
    __syncthreads();
     
    if(threadIdx.x == 0){
      IDX_DATA_TYPE end_pos = (i + step < stop_pos)? step : stop_pos - i;
      
        for(IDX_DATA_TYPE t = 0; t < end_pos; ++t){
          #if DEBUG == 1
          assert(shared_labels[t] < MAX_NUM_LABELS);
          #endif

          shared_count[shared_labels[t]]++;
                    
          if(shared_samples[t] == shared_samples[t + 1])
            continue;
          
          /*
          float imp_left, imp_right;
          imp_left  = calc_imp_left(shared_count, i + 1 + t) * (i + t + 1) / n_samples;
          imp_right  = calc_imp_right(shared_count, shared_count_total, n_samples - i - 1 - t) *
          (n_samples - i - 1 - t) / n_samples;
          calc_impurity(shared_count, shared_count_total, &imp_left, &imp_right, i + 1 + t, n_samples - i - 1 -t); 
          */          
          float imp_left = 0;
          float imp_right = 0;
          
          for(LABEL_DATA_TYPE r = 0; r < MAX_NUM_LABELS; ++r){
            float left_count = shared_count[r];
            imp_left += left_count * left_count;
            float right_count = shared_count_total[r] - left_count;
            imp_right += right_count * right_count; 
          }
          
          float n_left = i + 1 + t;
          float n_right = n_samples - n_left;
          //imp_left = n_left / n_samples - imp_left / (n_samples * n_left);
          //imp_right = (n_samples - n_left) / n_samples - imp_right / (n_samples * (n_samples - n_left));
          imp_left = (1 - imp_left / (n_left * n_left)) * (n_left / n_samples);
          imp_right = (1 - imp_right / (n_right * n_right)) * (n_right / n_samples);

          #if DEBUG == 1
          assert(imp_left >= -0.001 && imp_left <= 1.0);
          assert(imp_right >= -0.001 && imp_right <= 1.0);
          #endif

          if(imp_left + imp_right < reg_imp_right + reg_imp_left){
            reg_imp_left = imp_left;
            reg_imp_right = imp_right;
            reg_min_split = i + t;

            #if DEBUG == 1
            assert(reg_min_split < n_samples);
            #endif
          }  
        }
    }    
    __syncthreads();
  }
    
  if(threadIdx.x == 0){
    impurity_2d[blockIdx.x * MAX_BLOCK_PER_FEATURE * 2 + 2 * blockIdx.y] = reg_imp_left;
    impurity_2d[blockIdx.x * MAX_BLOCK_PER_FEATURE * 2 + 2 * blockIdx.y + 1] = reg_imp_right;
    split[blockIdx.x * MAX_BLOCK_PER_FEATURE + blockIdx.y] = reg_min_split;
    #if DEBUG == 1
    assert(reg_imp_left == 2.0 || (reg_imp_left >= 0.0 && reg_imp_left <= 1.0));
    assert(reg_imp_right == 2.0 || (reg_imp_right >= 0.0 && reg_imp_right <= 1.0));
    #endif
  }
}


__global__ void reduce_2d(
                      float *impurity_2d,
                      float *impurity_left,
                      float *impurity_right,
                      IDX_DATA_TYPE *split_2d,
                      IDX_DATA_TYPE *split_1d, 
                      int n_block
                      ){
  /* 
    Reduce the 2d impurity into 1d. Find best gini score and split index for each feature.
    The previous kernel produces the best gini score and best split for each range of the feature.
    Inputs: 
      - impurity_2d : the best gini score for each range of feature produced by previous kernel.
      - split_2d : the best split index of each range produced by previous kernel.
      - n_block : number of ranges.
    
    Outputs:
      - impurity_left : the best gini score on left part for the feature.
      - impurity_right : the best gini score on right part for the feature.
      - split_1d : the best split index of the who feature.
  */

  __shared__ float shared_imp[MAX_BLOCK_PER_FEATURE * 2];
  uint32_t imp_offset = blockIdx.x * MAX_BLOCK_PER_FEATURE * 2;
  uint32_t split_offset = blockIdx.x * MAX_BLOCK_PER_FEATURE;
  
  for(uint16_t t= threadIdx.x; t < n_block * 2; t += blockDim.x)
    shared_imp[t] = impurity_2d[imp_offset + t];
  
  __syncthreads();
  
  if(threadIdx.x == 0){
    float min_left = 2.0;
    float min_right = 2.0;
    uint16_t min_idx = 0;
    for(uint16_t i = 0; i < n_block; ++i)
      if(min_left + min_right > shared_imp[i * 2] + shared_imp[2 * i + 1]){
        min_left = shared_imp[i * 2];
        min_right = shared_imp[2 * i + 1];
        min_idx = i;
      }
    impurity_left[blockIdx.x] = min_left;
    impurity_right[blockIdx.x] = min_right;
    split_1d[blockIdx.x] = split_2d[split_offset + min_idx];
  }
}

/*
__global__ void compute_gini_small(IDX_DATA_TYPE *sorted_indices,
                        SAMPLE_DATA_TYPE *samples, 
                        LABEL_DATA_TYPE *labels,
                        float *imp_left, 
                        float *imp_right, 
                        COUNT_DATA_TYPE *label_total,
                        COUNT_DATA_TYPE *split, 
                        uint16_t *subset_indices,
                        int n_samples, 
                        int stride){
  uint32_t offset = subset_indices[blockIdx.x] * stride;
  IDX_DATA_TYPE stop_pos;
  float reg_imp_right = 2.0;
  float reg_imp_left = 2.0;
  COUNT_DATA_TYPE reg_min_split = 0;

  __shared__ float shared_count[MAX_NUM_LABELS];
  __shared__ float shared_count_total[MAX_NUM_LABELS];
  __shared__ LABEL_DATA_TYPE shared_labels[THREADS_PER_BLOCK];
  __shared__ SAMPLE_DATA_TYPE shared_samples[THREADS_PER_BLOCK];
  

  for(uint16_t i = threadIdx.x; i < MAX_NUM_LABELS; i += blockDim.x){   
      shared_count[i] = 0;
      shared_count_total[i] = label_total[i];
  }
  
  IDX_DATA_TYPE end_pos = n_samples - 1;

  for(IDX_DATA_TYPE i = threadIdx.x; i < end_pos; i += blockDim.x){ 
    IDX_DATA_TYPE idx = sorted_indices[offset + i];
    shared_labels[threadIdx.x] = labels[idx]; 
    shared_samples[threadIdx.x] = samples[offset + idx];

    __syncthreads();
    
    if(threadIdx.x == 0){
      stop_pos = (i + blockDim.x < end_pos)? blockDim.x : end_pos - i;
      
        for(IDX_DATA_TYPE t = 0; t < stop_pos; ++t){
          shared_count[shared_labels[t]]++;
                    
          if(t != stop_pos - 1){
            if(shared_samples[t] == shared_samples[t + 1])
              continue;
          }
          else if(shared_samples[t] == samples[offset + sorted_indices[offset + stop_pos + i]])
            continue;
          
          float imp_left = calc_imp_left(shared_count, i + 1 + t) * (i + t + 1) / n_samples;
          float imp_right = calc_imp_right(shared_count, shared_count_total, n_samples - i - 1 - t) *
            (n_samples - i - 1 - t) / n_samples;
          
          if(imp_left + imp_right < reg_imp_right + reg_imp_left){
            reg_imp_left = imp_left;
            reg_imp_right = imp_right;
            reg_min_split = i + t;
          }  
        }
    }    
    __syncthreads();
  }
    
  if(threadIdx.x == 0){
    split[blockIdx.x] = reg_min_split;
    imp_left[blockIdx.x] = reg_imp_left;
    imp_right[blockIdx.x] = reg_imp_right;
  }
}

__global__ void scan_gini_small(
                        IDX_DATA_TYPE *sorted_indices,
                        LABEL_DATA_TYPE *labels, 
                        COUNT_DATA_TYPE *label_total,
                        int n_samples
                        ){
   
  __shared__ COUNT_DATA_TYPE shared_count[MAX_NUM_LABELS];
  __shared__ LABEL_DATA_TYPE shared_labels[THREADS_PER_BLOCK]; 
  IDX_DATA_TYPE stop_pos;
  
  for(uint16_t i = threadIdx.x; i < MAX_NUM_LABELS; i += blockDim.x)
    shared_count[i] = 0;
  
  for(IDX_DATA_TYPE i = 0; i < n_samples; i += blockDim.x){
    IDX_DATA_TYPE idx = i + threadIdx.x;
    if(idx < n_samples)
      shared_labels[threadIdx.x] = labels[sorted_indices[idx]];
    
    __syncthreads();

    if(threadIdx.x == 0){
      stop_pos = (i + blockDim.x < n_samples)? blockDim.x : n_samples - i;

      for(IDX_DATA_TYPE t = 0; t < stop_pos; ++t)
        shared_count[shared_labels[t]]++;
    } 

    __syncthreads();
  }
  
  for(uint16_t i =  threadIdx.x; i < MAX_NUM_LABELS; i += blockDim.x)
    label_total[i] = shared_count[i];
}
*/
