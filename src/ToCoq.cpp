/*
 * Copyright (c) 2020 BedRock Systems, Inc.
 * This software is distributed under the terms of the BedRock Open-Source License.
 * See the LICENSE-BedRock file in the repository root for details.
 */
#include "ClangPrinter.hpp"
#include "CommentScanner.hpp"
#include "CoqPrinter.hpp"
#include "Filter.hpp"
#include "ModuleBuilder.hpp"
#include "SpecCollector.hpp"
#include "clang/AST/Decl.h"
#include "clang/AST/DeclCXX.h"
#include "clang/AST/DeclTemplate.h"
#include "clang/AST/Type.h"
#include "clang/Basic/FileManager.h"
#include "clang/Basic/TargetInfo.h"
#include "clang/Basic/Version.inc"
#include <Formatter.hpp>
#include <list>

#include "clang/AST/ASTConsumer.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/FrontendAction.h"

// Declares clang::SyntaxOnlyAction.
#include "clang/Frontend/FrontendActions.h"

#include "SpecCollector.hpp"
#include "ToCoq.hpp"

using namespace clang;
using namespace fmt;

void
ToCoqConsumer::toCoqModule(clang::ASTContext *ctxt,
                           clang::TranslationUnitDecl *decl) {
#if 0
	NoInclude noInclude(ctxt->getSourceManager());
	FromComment fromComment(ctxt);
	std::list<Filter*> filters;
	filters.push_back(&noInclude);
	filters.push_back(&fromComment);
	Combine<Filter::What::NOTHING, Filter::max> filter(filters);
#endif
    SpecCollector specs;
    Default filter(Filter::What::DEFINITION);

    ::Module mod;

    build_module(decl, mod, filter, specs, compiler_);

    if (output_file_.hasValue()) {
        std::error_code ec;
        llvm::raw_fd_ostream code_output(*output_file_, ec);
        if (ec.value()) {
            llvm::errs() << "Failed to open generation file: " << *output_file_
                         << "\n"
                         << ec.message() << "\n";
        } else {
            Formatter fmt(code_output);
            CoqPrinter print(fmt);
            ClangPrinter cprint(compiler_, ctxt);

            fmt << "Require Import bedrock.lang.cpp.parser." << fmt::line
                << fmt::line << "Local Open Scope bs_scope." << fmt::line;
            // << "Import ListNotations." << fmt::line;

            fmt << fmt::line
                << "Definition module : translation_unit := " << fmt::indent
                << fmt::line << "Eval reduce_translation_unit in decls"
                << fmt::nbsp;

            print.begin_list();
            for (auto entry : mod.imports()) {
                auto decl = entry.second.first;
                if (cprint.printDecl(decl, print))
                    print.cons();
            }
            for (auto entry : mod.definitions()) {
                auto decl = entry.second;
                if (cprint.printDecl(decl, print))
                    print.cons();
            }
            print.end_list();
            print.output() << fmt::nbsp;
            if (ctxt->getTargetInfo().isBigEndian()) {
                print.output() << "Big";
            } else {
                assert(ctxt->getTargetInfo().isLittleEndian());
                print.output() << "Little";
            }
            print.output() << "." << fmt::outdent << fmt::line;
        }
    }

    if (notations_file_.hasValue()) {
        std::error_code ec;
        llvm::raw_fd_ostream notations_output(*notations_file_, ec);
        if (ec.value()) {
            llvm::errs() << "Failed to open notations file: "
                         << *notations_file_ << "\n"
                         << ec.message() << "\n";
        } else {
            fmt::Formatter spec_fmt(notations_output);
            auto &ctxt = decl->getASTContext();
            ClangPrinter cprint(compiler_, &decl->getASTContext());
            CoqPrinter print(spec_fmt);
            // PrintSpec printer(ctxt);

            NoInclude source(ctxt.getSourceManager());

            print.output() << "(*" << fmt::line
                           << " * Notations extracted from "
                           << ctxt.getSourceManager()
                                  .getFileEntryForID(
                                      ctxt.getSourceManager().getMainFileID())
                                  ->getName()
                           << fmt::line << " *)" << fmt::line
                           << "Require Export bedrock.lang.cpp.parser."
                           << fmt::line << fmt::line;

            // generate all of the record fields
            write_globals(mod, print, cprint);
        }
    }

    if (spec_file_.hasValue()) {
        llvm::errs() << "writing specifications is no longer supported!\n";
#if 0
        std::error_code ec;
        llvm::raw_fd_ostream spec_output(*spec_file_, ec);
        if (ec.value()) {
            llvm::errs() << "Failed to open specification file: " << *spec_file_
                         << "\n"
                         << ec.message() << "\n";
        } else {
            fmt::Formatter spec_fmt(spec_output);
            write_spec(compiler_, &mod, specs, decl, filter, spec_fmt);
        }
#endif
    }
}
