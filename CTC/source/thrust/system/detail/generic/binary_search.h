/*
 *  Copyright 2008-2012 NVIDIA Corporation
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */


/*! \file binary_search.h
 *  \brief Generic implementations of binary search functions.
 */

#pragma once

#include <thrust/detail/config.h>
#include <thrust/system/detail/generic/tag.h>

namespace thrust
{
namespace system
{
namespace detail
{
namespace generic
{


template <typename DerivedPolicy, typename ForwardIterator, typename T>
ForwardIterator lower_bound(thrust::execution_policy<DerivedPolicy> &exec, 
                            ForwardIterator begin,
                            ForwardIterator end,
                            const T& value);

template <typename DerivedPolicy, typename ForwardIterator, typename T, typename StrictWeakOrdering>
ForwardIterator lower_bound(thrust::execution_policy<DerivedPolicy> &exec,
                            ForwardIterator begin,
                            ForwardIterator end,
                            const T& value, 
                            StrictWeakOrdering comp);


template <typename DerivedPolicy, typename ForwardIterator, typename T>
ForwardIterator upper_bound(thrust::execution_policy<DerivedPolicy> &exec,
                            ForwardIterator begin,
                            ForwardIterator end,
                            const T& value);

template <typename DerivedPolicy, typename ForwardIterator, typename T, typename StrictWeakOrdering>
ForwardIterator upper_bound(thrust::execution_policy<DerivedPolicy> &exec, 
                            ForwardIterator begin,
                            ForwardIterator end,
                            const T& value, 
                            StrictWeakOrdering comp);


template <typename DerivedPolicy, typename ForwardIterator, typename T>
bool binary_search(thrust::execution_policy<DerivedPolicy> &exec,
                   ForwardIterator begin,
                   ForwardIterator end,
                   const T& value);

template <typename DerivedPolicy, typename ForwardIterator, typename T, typename StrictWeakOrdering>
bool binary_search(thrust::execution_policy<DerivedPolicy> &exec,
                   ForwardIterator begin,
                   ForwardIterator end,
                   const T& value, 
                   StrictWeakOrdering comp);


template <typename DerivedPolicy, typename ForwardIterator, typename InputIterator, typename OutputIterator>
OutputIterator lower_bound(thrust::execution_policy<DerivedPolicy> &exec,
                           ForwardIterator begin, 
                           ForwardIterator end,
                           InputIterator values_begin, 
                           InputIterator values_end,
                           OutputIterator output);

template <typename DerivedPolicy, typename ForwardIterator, typename InputIterator, typename OutputIterator, typename StrictWeakOrdering>
OutputIterator lower_bound(thrust::execution_policy<DerivedPolicy> &exec,
                           ForwardIterator begin, 
                           ForwardIterator end,
                           InputIterator values_begin, 
                           InputIterator values_end,
                           OutputIterator output,
                           StrictWeakOrdering comp);


template <typename DerivedPolicy, typename ForwardIterator, typename InputIterator, typename OutputIterator>
OutputIterator upper_bound(thrust::execution_policy<DerivedPolicy> &exec,
                           ForwardIterator begin, 
                           ForwardIterator end,
                           InputIterator values_begin, 
                           InputIterator values_end,
                           OutputIterator output);

template <typename DerivedPolicy, typename ForwardIterator, typename InputIterator, typename OutputIterator, typename StrictWeakOrdering>
OutputIterator upper_bound(thrust::execution_policy<DerivedPolicy> &exec,
                           ForwardIterator begin, 
                           ForwardIterator end,
                           InputIterator values_begin, 
                           InputIterator values_end,
                           OutputIterator output,
                           StrictWeakOrdering comp);


template <typename DerivedPolicy, typename ForwardIterator, typename InputIterator, typename OutputIterator>
OutputIterator binary_search(thrust::execution_policy<DerivedPolicy> &exec,
                             ForwardIterator begin, 
                             ForwardIterator end,
                             InputIterator values_begin, 
                             InputIterator values_end,
                             OutputIterator output);

template <typename DerivedPolicy, typename ForwardIterator, typename InputIterator, typename OutputIterator, typename StrictWeakOrdering>
OutputIterator binary_search(thrust::execution_policy<DerivedPolicy> &exec,
                             ForwardIterator begin, 
                             ForwardIterator end,
                             InputIterator values_begin, 
                             InputIterator values_end,
                             OutputIterator output,
                             StrictWeakOrdering comp);


template <typename DerivedPolicy, typename ForwardIterator, typename LessThanComparable>
thrust::pair<ForwardIterator,ForwardIterator>
equal_range(thrust::execution_policy<DerivedPolicy> &exec,
            ForwardIterator first,
            ForwardIterator last,
            const LessThanComparable &value);

template <typename DerivedPolicy, typename ForwardIterator, typename LessThanComparable, typename StrictWeakOrdering>
thrust::pair<ForwardIterator,ForwardIterator>
equal_range(thrust::execution_policy<DerivedPolicy> &exec,
            ForwardIterator first,
            ForwardIterator last,
            const LessThanComparable &value,
            StrictWeakOrdering comp);



} // end namespace generic
} // end namespace detail
} // end namespace system
} // end namespace thrust

#include <thrust/system/detail/generic/binary_search.inl>

