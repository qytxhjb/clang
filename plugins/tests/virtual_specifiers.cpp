// Copyright 2014 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Tests for chromium style checks for virtual/override/final specifiers on
// virtual methods.

// Purposely use macros to test that the FixIt hints don't try to remove the
// macro body.
#define OVERRIDE override
#define FINAL final

// Base class can only use virtual.
class Base {
 public:
  virtual ~Base() {}
  virtual void F() = 0;
};

// Derived classes correctly use only override or final specifier.
class CorrectOverride : public Base {
 public:
  ~CorrectOverride() OVERRIDE {}
  void F() OVERRIDE {}
};

class CorrectFinal : public CorrectOverride {
 public:
  ~CorrectFinal() FINAL {}
  void F() FINAL {}
};

// No override on an overridden method should trigger a diagnostic.
class MissingOverride : public Base {
 public:
  ~MissingOverride() {}
  void F() {}
};

// Redundant specifiers should trigger a diagnostic.
class VirtualAndOverride : public Base {
 public:
  virtual ~VirtualAndOverride() OVERRIDE {}
  virtual void F() OVERRIDE {}
};

class VirtualAndFinal : public Base {
 public:
  virtual ~VirtualAndFinal() FINAL {}
  virtual void F() FINAL {}
};

class VirtualAndOverrideFinal : public Base {
 public:
  virtual ~VirtualAndOverrideFinal() OVERRIDE FINAL {}
  virtual void F() OVERRIDE FINAL {}
};

class OverrideAndFinal : public Base {
 public:
  ~OverrideAndFinal() OVERRIDE FINAL {}
  void F() OVERRIDE FINAL {}
};
