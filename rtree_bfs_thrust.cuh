 
#include<stdio.h>
#include<math.h>
#include<stdlib.h>
#include<assert.h>
#include<thrust/device_vector.h>
#include<thrust/copy.h>
#include<thrust/sort.h>
#include<thrust/reduce.h>
#include<thrust/iterator/counting_iterator.h>
#include<thrust/iterator/constant_iterator.h>
#include<thrust/iterator/transform_iterator.h>
#include<thrust/iterator/zip_iterator.h>
#include<thrust/iterator/discard_iterator.h>
#include<thrust/tuple.h>
#include<thrust/merge.h>
#include<thrust/remove.h>
#include<thrust/transform.h>
#include<thrust/functional.h>
#include<thrust/fill.h>
#include<iostream>
#include<vector>
#include<time.h>
#include<sys/time.h>

#include "rtree.h"
#include "utility.h"
#include "utility.cuh"

using namespace std;
using namespace thrust::placeholders;

struct is_non_leaf {
  int sz;
  is_non_leaf(int _sz) : sz(_sz) {}
  __host__ __device__
    bool operator()(thrust::tuple<int, int, bool> val) {
    //tuple is (qid,nid,flag); qid is not needed but the vector needs to be reordered by partition
      int nid=thrust::get<1>(val);
      return (nid >= 0 && nid<sz && thrust::get<2>(val));
    }
};


__host__ __device__ __inline__ bool intersect(float x1, float y1, float x2, float y2,
                          float m1, float n1, float m2, float n2)
{
    if (x1 > m2 || x2 < m1 || y1 > n2 || y2 < n1)
        return false;
    return true;    
}

template <class T>
struct d_node_intersect 
: thrust::unary_function<thrust::tuple<int, int>, bool> {
  RTREE<T> rt;
  BBOX<T>  qbox;
  d_node_intersect(const RTREE<T>& _rt,const BBOX<T>& _qbox)
    : rt(_rt),qbox(_qbox) {}

  __host__ __device__
    bool operator()(thrust::tuple<int, int> item) {
      int qid = thrust::get<0>(item);
      int nid = thrust::get<1>(item);
      return(intersect(qbox.xmin[qid],qbox.ymin[qid],qbox.xmax[qid],qbox.ymax[qid],
          rt.xmin[nid],rt.ymin[nid],rt.xmax[nid],rt.ymax[nid]));
    }
};

template <class T>
struct d_box_intersect 
: thrust::unary_function<thrust::tuple<int, int>, bool> {
  BBOX<T>  rbox,qbox;
  int offset;
  d_box_intersect(const BBOX<T>& _qbox,const BBOX<T>& _rbox,int _offset)
    : rbox(_rbox),qbox(_qbox),offset(_offset) {}

  __host__ __device__
    bool operator()(thrust::tuple<int, int> item) {
      int qid = thrust::get<0>(item);
      int bid = thrust::get<1>(item)-offset;
      return(intersect(qbox.xmin[qid],qbox.ymin[qid],qbox.xmax[qid],qbox.ymax[qid],
          rbox.xmin[bid],rbox.ymin[bid],rbox.xmax[bid],rbox.ymax[bid]));
    }
};

template <class T>
struct lookup_box_id
{
   int offset,*ids;
   lookup_box_id(int _offset,int *_ids):offset(_offset),ids(_ids){}
   
   __host__ __device__
    int operator()(int idx) {
         return ids[idx-offset];
    }
};



//d_dq: (box,query)<==>(f,t)
template <class T>
void bfs_thrust(const RTREE<T>& d_rt,const BBOX<T>& d_rbox,const BBOX<T>& d_qbox,IDPAIR& d_dq)
{
  int q_size=d_qbox.sz;
  int work_sz = q_size*1;

  thrust::device_ptr<int> d_rt_pos=thrust::device_pointer_cast(d_rt.pos);
  thrust::device_ptr<int> d_rt_len=thrust::device_pointer_cast(d_rt.len);
  
  thrust::device_vector<int> d_tmp_qid_vec(work_sz, -1);
  thrust::device_vector<int> d_tmp_nid_vec(work_sz, -1);
  
  thrust::sequence(d_tmp_qid_vec.begin(),d_tmp_qid_vec.begin()+work_sz);

  //root id always begin with position 0
  thrust::fill_n(d_tmp_nid_vec.begin(),work_sz,0);
      
  timeval t0, t1;
  gettimeofday(&t0, NULL);
  
  int total_result_sz = 0;
  int lev=0;

  while(work_sz>0){
    std::cout<<"lev="<<lev<<" work_sz="<<work_sz<<std::endl; 
    thrust::device_vector<bool> d_intersect_flag(work_sz);    
    auto d_tmp1_ptr=thrust::make_zip_iterator(thrust::make_tuple(d_tmp_qid_vec.begin(), d_tmp_nid_vec.begin()));           
    thrust::transform(d_tmp1_ptr,d_tmp1_ptr+work_sz,d_intersect_flag.begin(),d_node_intersect<T>(d_rt,d_qbox));
    
    //partition the queue by moving intersected non-leaf nodes to front
    auto d_nqf_ptr= thrust::make_zip_iterator(
            thrust::make_tuple(d_tmp_qid_vec.begin(), d_tmp_nid_vec.begin(),d_intersect_flag.begin()));
        
    int valid_sz =
      thrust::stable_partition(d_nqf_ptr, d_nqf_ptr+work_sz,is_non_leaf(d_rt.sz))-d_nqf_ptr;

    d_intersect_flag.resize(0);
    d_intersect_flag.shrink_to_fit();

    std::cout<<"lev="<<lev<<" work_sz="<<work_sz<<" valid_sz="<<valid_sz<<std::endl; 
    total_result_sz += valid_sz;
     
    if (valid_sz <= 0)
      break;
           
    //expand for next loop; assume d_map[0] is initialized to 0
    thrust::device_vector<int> d_map(valid_sz+1,0);

    auto d_len_ptr=thrust::make_permutation_iterator(d_rt_len, d_tmp_nid_vec.begin());
    thrust::inclusive_scan(d_len_ptr,d_len_ptr+valid_sz,d_map.begin()+1);

    int next_size = d_map.back();
    std::cout<<"lev="<<lev<<" next_size="<<next_size<<std::endl; 
    if (next_size <= 0)
      break;
  
    thrust::device_vector<int> d_next_qid_vec(next_size, -1);
    thrust::device_vector<int> d_next_nid_vec(next_size, -1);

    //handling qid 
    auto counting_iter=thrust::make_counting_iterator(0);
    thrust::scatter(d_tmp_qid_vec.begin(),d_tmp_qid_vec.begin()+valid_sz,d_map.begin(),d_next_qid_vec.begin());
    thrust::inclusive_scan(d_next_qid_vec.begin(),d_next_qid_vec.begin()+next_size,d_next_qid_vec.begin(),thrust::maximum<int>());
 
  
   //handling nid   
    auto  node_pos_ptr=thrust::make_permutation_iterator( d_rt_pos, d_tmp_nid_vec.begin());   
   thrust::scatter(node_pos_ptr,node_pos_ptr+valid_sz,d_map.begin(),d_next_nid_vec.begin());
   thrust::inclusive_scan_by_key(d_next_qid_vec.begin(),d_next_qid_vec.begin()+next_size,d_next_nid_vec.begin(),
        d_next_nid_vec.begin(),thrust::equal_to<int>(),thrust::maximum<int>());

   //generate offset array
    thrust::device_vector<int> d_offset(next_size, -1);

    thrust::scatter(
        d_map.begin(),
        d_map.begin()+valid_sz,
        d_map.begin(),
        d_offset.begin());
    thrust::inclusive_scan(d_offset.begin(), d_offset.end(),
        d_offset.begin(), thrust::maximum<int>());

    thrust::transform(
        d_offset.begin(),
        d_offset.end(),
        thrust::make_counting_iterator(0),
        d_offset.begin(),
        _2 - _1);

    thrust::transform(
        d_next_nid_vec.begin(), 
        d_next_nid_vec.begin()+next_size,
        d_offset.begin(),
        d_next_nid_vec.begin(),
        _1 + _2);

    d_map.resize(0);
    d_offset.resize(0);
    d_map.shrink_to_fit();
    d_offset.shrink_to_fit();
    
    d_tmp_qid_vec.resize(0);
    d_tmp_nid_vec.resize(0);
    d_tmp_qid_vec.shrink_to_fit();
    d_tmp_nid_vec.shrink_to_fit();

    d_tmp_qid_vec.swap(d_next_qid_vec);
    d_tmp_nid_vec.swap(d_next_nid_vec);

    d_next_qid_vec.resize(0);
    d_next_nid_vec.resize(0);
    d_next_qid_vec.shrink_to_fit();
    d_next_nid_vec.shrink_to_fit();
    
    work_sz = next_size;
    lev++;   
  }
  std::cout<<final work_sz="<<work_sz<<std::endl;
   
  //remove (qid,boxid) pairs that do not intersect  
  auto out_qb_ptr=thrust::make_zip_iterator(thrust::make_tuple(d_tmp_qid_vec.begin(), d_tmp_nid_vec.begin()));
  int result_sz = thrust::copy_if(out_qb_ptr,out_qb_ptr+work_sz,out_qb_ptr,
      d_box_intersect<T>(d_qbox,d_rbox,d_rt.sz))-out_qb_ptr;
  std::cout<<"result_sz="<<result_sz<<std::endl;
  
  idpair_d_alloc(result_sz,d_dq);
  thrust::device_ptr<int> d_nid_ptr=thrust::device_pointer_cast(d_dq.fid);
  thrust::device_ptr<int> d_qid_ptr=thrust::device_pointer_cast(d_dq.tid);

  //substract offset so that box id begins with 0 (originally relative to root node position)
  thrust::transform(d_tmp_nid_vec.begin(),d_tmp_nid_vec.begin()+result_sz,
  	d_nid_ptr,lookup_box_id<T>(d_rt.sz,d_rbox.id));     
  thrust::copy(d_tmp_qid_vec.begin(),d_tmp_qid_vec.begin()+result_sz,d_qid_ptr);

  gettimeofday(&t1, NULL);
  float run_time = t1.tv_sec * 1000000 + t1.tv_usec - t0.tv_sec * 1000000 - t0.tv_usec;
  std::cout<<"thrust bfs end-to-end time="<<run_time/1000 <<"ms"<<std::endl;         
}
