// Copyright 2022 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "FindBadRawPtrPatterns.h"

#include "RawPtrHelpers.h"
#include "RawPtrManualPathsToIgnore.h"
#include "StackAllocatedChecker.h"
#include "Util.h"
#include "clang/AST/AST.h"
#include "clang/AST/ASTConsumer.h"
#include "clang/AST/Attr.h"
#include "clang/AST/CXXInheritance.h"
#include "clang/AST/TypeLoc.h"
#include "clang/ASTMatchers/ASTMatchFinder.h"
#include "clang/ASTMatchers/ASTMatchers.h"
#include "clang/Basic/SourceLocation.h"
#include "clang/Basic/SourceManager.h"

using namespace clang;
using namespace clang::ast_matchers;

namespace chrome_checker {

const char kBadCastSignature[] =
    "[chromium-raw-ptr-cast] Casting raw_ptr<T>* to another type is not "
    "allowed as it may cause BRP ref count mismatch and bypass security "
    "checks.";

class BadCastMatcher : public MatchFinder::MatchCallback {
 public:
  explicit BadCastMatcher(clang::CompilerInstance& compiler)
      : compiler_(compiler) {
    error_bad_raw_ptr_cast_signature_ =
        compiler_.getDiagnostics().getCustomDiagID(
            clang::DiagnosticsEngine::Error, kBadCastSignature);
  }

  void Register(MatchFinder& match_finder) {
    // TODO(keishi): Also find casts to and from classes that contain raw_ptr.
    auto cast_matcher =
        castExpr(
            allOf(hasSourceExpression(hasType(pointerType(pointee(
                      hasUnqualifiedDesugaredType(recordType(hasDeclaration(
                          cxxRecordDecl(classTemplateSpecializationDecl(
                              hasName("base::raw_ptr")))))))))),
                  hasCastKind(CK_BitCast)))
            .bind("castExpr");
    match_finder.addMatcher(cast_matcher, this);
  }

  void run(const MatchFinder::MatchResult& result) override {
    const clang::CastExpr* cast_expr =
        result.Nodes.getNodeAs<clang::CastExpr>("castExpr");
    assert(cast_expr && "matcher should bind 'castExpr'");

    const clang::SourceManager& source_manager = *result.SourceManager;
    clang::SourceLocation loc = cast_expr->getSourceRange().getBegin();
    std::string file_path = GetFilename(source_manager, loc);

    // Using raw_ptr<T> in a stdlib collection will cause a cast.
    // e.g.
    // https://source.chromium.org/chromium/chromium/src/+/main:components/feed/core/v2/xsurface_datastore.h;drc=a0ff03edcace35ec020edd235f4d9e9735fc9690;l=107
    if (file_path.find("buildtools/third_party/libc++") != std::string::npos)
      return;
    // CHECK(raw_ptr<T>) will cause a cast.
    // e.g.
    // https://source.chromium.org/chromium/chromium/src/+/main:base/task/sequence_manager/thread_controller_with_message_pump_impl.cc;drc=c49b7434a9d4a61c49fc0123e904a6c5e7162731;l=121
    if (file_path.find("base/check_op.h") != std::string::npos)
      return;
    // raw_ptr<T>* is cast to ui::metadata::PropertyKey
    // https://source.chromium.org/chromium/chromium/src/+/main:ui/views/view.cc;drc=a0ff03edcace35ec020edd235f4d9e9735fc9690;l=2417
    if (file_path.find("ui/views/controls/table/table_view.cc") !=
        std::string::npos)
      return;
    // XdgActivation::activation_queue_ is a base::queue<raw_ptr> which causes a
    // cast in VectorBuffer and circular_deque.
    if (file_path.find("base/containers/vector_buffer.h") != std::string::npos)
      return;
    if (file_path.find("base/containers/circular_deque.h") != std::string::npos)
      return;

    compiler_.getDiagnostics().Report(cast_expr->getEndLoc(),
                                      error_bad_raw_ptr_cast_signature_);
  }

 private:
  clang::CompilerInstance& compiler_;
  unsigned error_bad_raw_ptr_cast_signature_;
};

const char kNeedRawPtrSignature[] =
    "[chromium-rawptr] Use raw_ptr<T> instead of a raw pointer.";

class RawPtrFieldMatcher : public MatchFinder::MatchCallback {
 public:
  explicit RawPtrFieldMatcher(
      clang::CompilerInstance& compiler,
      const RawPtrAndRefExclusionsOptions& exclusion_options)
      : compiler_(compiler), exclusion_options_(exclusion_options) {
    error_need_raw_ptr_signature_ = compiler_.getDiagnostics().getCustomDiagID(
        clang::DiagnosticsEngine::Error, kNeedRawPtrSignature);
  }

  void Register(MatchFinder& match_finder) {
    auto field_decl_matcher = AffectedRawPtrFieldDecl(exclusion_options_);
    match_finder.addMatcher(field_decl_matcher, this);
  }
  void run(const MatchFinder::MatchResult& result) override {
    const clang::FieldDecl* field_decl =
        result.Nodes.getNodeAs<clang::FieldDecl>("affectedFieldDecl");
    assert(field_decl && "matcher should bind 'fieldDecl'");

    const clang::TypeSourceInfo* type_source_info =
        field_decl->getTypeSourceInfo();
    assert(type_source_info && "assuming |type_source_info| is always present");

    assert(type_source_info->getType()->isPointerType() &&
           "matcher should only match pointer types");

    compiler_.getDiagnostics().Report(field_decl->getEndLoc(),
                                      error_need_raw_ptr_signature_);
  }

 private:
  clang::CompilerInstance& compiler_;
  unsigned error_need_raw_ptr_signature_;
  const RawPtrAndRefExclusionsOptions& exclusion_options_;
};

const char kNeedRawRefSignature[] =
    "[chromium-rawref] Use raw_ref<T> instead of a native reference.";

class RawRefFieldMatcher : public MatchFinder::MatchCallback {
 public:
  explicit RawRefFieldMatcher(
      clang::CompilerInstance& compiler,
      const RawPtrAndRefExclusionsOptions& exclusion_options)
      : compiler_(compiler), exclusion_options_(exclusion_options) {
    error_need_raw_ref_signature_ = compiler_.getDiagnostics().getCustomDiagID(
        clang::DiagnosticsEngine::Error, kNeedRawRefSignature);
  }

  void Register(MatchFinder& match_finder) {
    auto field_decl_matcher = AffectedRawRefFieldDecl(exclusion_options_);
    match_finder.addMatcher(field_decl_matcher, this);
  }
  void run(const MatchFinder::MatchResult& result) override {
    const clang::FieldDecl* field_decl =
        result.Nodes.getNodeAs<clang::FieldDecl>("affectedFieldDecl");
    assert(field_decl && "matcher should bind 'fieldDecl'");

    const clang::TypeSourceInfo* type_source_info =
        field_decl->getTypeSourceInfo();
    assert(type_source_info && "assuming |type_source_info| is always present");

    assert(type_source_info->getType()->isReferenceType() &&
           "matcher should only match reference types");

    compiler_.getDiagnostics().Report(field_decl->getEndLoc(),
                                      error_need_raw_ref_signature_);
  }

 private:
  clang::CompilerInstance& compiler_;
  unsigned error_need_raw_ref_signature_;
  const RawPtrAndRefExclusionsOptions exclusion_options_;
};

const char kNoRawPtrToStackAllocatedSignature[] =
    "[chromium-raw-ptr-to-stack-allocated] Do not use '%0<T>' on a "
    "`STACK_ALLOCATED` object '%1'.";

class RawPtrToStackAllocatedMatcher : public MatchFinder::MatchCallback {
 public:
  explicit RawPtrToStackAllocatedMatcher(clang::CompilerInstance& compiler)
      : compiler_(compiler), stack_allocated_predicate_() {
    error_no_raw_ptr_to_stack_ = compiler_.getDiagnostics().getCustomDiagID(
        clang::DiagnosticsEngine::Error, kNoRawPtrToStackAllocatedSignature);
  }

  void Register(MatchFinder& match_finder) {
    auto value_decl_matcher =
        RawPtrToStackAllocatedTypeLoc(&stack_allocated_predicate_);
    match_finder.addMatcher(value_decl_matcher, this);
  }
  void run(const MatchFinder::MatchResult& result) override {
    const auto* pointer =
        result.Nodes.getNodeAs<clang::CXXRecordDecl>("pointerRecordDecl");
    assert(pointer && "matcher should bind 'pointerRecordDecl'");

    const auto* pointee =
        result.Nodes.getNodeAs<clang::QualType>("pointeeQualType");
    assert(pointee && "matcher should bind 'pointeeQualType'");
    clang::PrintingPolicy printing_policy(result.Context->getLangOpts());
    const std::string pointee_name = pointee->getAsString(printing_policy);

    const auto* type_loc =
        result.Nodes.getNodeAs<clang::TypeLoc>("stackAllocatedRawPtrTypeLoc");
    assert(type_loc && "matcher should bind 'stackAllocatedRawPtrTypeLoc'");

    compiler_.getDiagnostics().Report(type_loc->getEndLoc(),
                                      error_no_raw_ptr_to_stack_)
        << pointer->getNameAsString() << pointee_name;
  }

 private:
  clang::CompilerInstance& compiler_;
  StackAllocatedPredicate stack_allocated_predicate_;
  unsigned error_no_raw_ptr_to_stack_;
};

void FindBadRawPtrPatterns(Options options,
                           clang::ASTContext& ast_context,
                           clang::CompilerInstance& compiler) {
  MatchFinder match_finder;

  BadCastMatcher bad_cast_matcher(compiler);
  if (options.check_bad_raw_ptr_cast)
    bad_cast_matcher.Register(match_finder);

  std::vector<std::string> paths_to_exclude_lines;
  for (auto* const line : kRawPtrManualPathsToIgnore) {
    paths_to_exclude_lines.push_back(line);
  }
  paths_to_exclude_lines.insert(paths_to_exclude_lines.end(),
                                options.raw_ptr_paths_to_exclude_lines.begin(),
                                options.raw_ptr_paths_to_exclude_lines.end());

  FilterFile exclude_fields(options.exclude_fields_file, "exclude-fields");
  FilterFile exclude_lines(paths_to_exclude_lines);
  StackAllocatedPredicate stack_allocated_predicate;
  RawPtrAndRefExclusionsOptions exclusion_options{
      &exclude_fields, &exclude_lines, options.check_raw_ptr_to_stack_allocated,
      &stack_allocated_predicate};

  RawPtrFieldMatcher field_matcher(compiler, exclusion_options);
  if (options.check_raw_ptr_fields) {
    field_matcher.Register(match_finder);
  }

  RawRefFieldMatcher ref_field_matcher(compiler, exclusion_options);
  if (options.check_raw_ref_fields) {
    ref_field_matcher.Register(match_finder);
  }

  RawPtrToStackAllocatedMatcher raw_ptr_to_stack(compiler);
  if (options.check_raw_ptr_to_stack_allocated) {
    raw_ptr_to_stack.Register(match_finder);
  }

  match_finder.matchAST(ast_context);
}

}  // namespace chrome_checker
