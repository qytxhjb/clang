// Copyright 2022 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef TOOLS_CLANG_RAW_PTR_PLUGIN_TESTS_BASE_MEMORY_RAW_PTR_EXCLUSION_H_
#define TOOLS_CLANG_RAW_PTR_PLUGIN_TESTS_BASE_MEMORY_RAW_PTR_EXCLUSION_H_

// Although `raw_ptr` is part of the standalone PA distribution, it is
// easier to use the shorter path in `//base/memory`. We retain this
// facade header for ease of typing.
#include "partition_alloc/pointers/raw_ptr_exclusion.h"  // IWYU pragma: export

#endif  // TOOLS_CLANG_RAW_PTR_PLUGIN_TESTS_BASE_MEMORY_RAW_PTR_EXCLUSION_H_
