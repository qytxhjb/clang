// Copyright 2014 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "inner_class.h"

namespace WebCore {

void SomeObject::InnerObject::trace(Visitor* visitor)
{
    // Missing: visitor->trace(m_obj);
}

}
