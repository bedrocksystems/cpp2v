/*
 * Copyright (c) 2020 BedRock Systems, Inc.
 * This software is distributed under the terms of the BedRock Open-Source License.
 * See the LICENSE-BedRock file in the repository root for details.
 */
#include "ClangPrinter.hpp"
#include "CoqPrinter.hpp"
#include "DeclVisitorWithArgs.h"
#include "Formatter.hpp"
#include "Logging.hpp"
#include "OpaqueNames.hpp"

using namespace clang;

class PrintLocalDecl :
    public ConstDeclVisitorArgs<PrintLocalDecl, bool, CoqPrinter&,
                                ClangPrinter&, OpaqueNames&> {
private:
    PrintLocalDecl() {}

    static CXXDestructorDecl* get_dtor(QualType qt) {
        if (auto rd = qt->getAsCXXRecordDecl()) {
            return rd->getDestructor();
        } else if (auto ary = qt->getAsArrayTypeUnsafe()) {
            return get_dtor(ary->getElementType());
        } else {
            return nullptr;
        }
    }

    static void printDestructor(QualType qt, CoqPrinter& print,
                                ClangPrinter& cprint) {
        // TODO when destructors move to classes, we can change this
        if (auto dest = get_dtor(qt)) {
            print.some();
            cprint.printObjName(dest, print);
            print.end_ctor();
        } else {
            print.none();
        }
    }

public:
    static PrintLocalDecl printer;

    bool VisitVarDecl(const VarDecl* decl, CoqPrinter& print,
                      ClangPrinter& cprint, OpaqueNames& on) {
        print.ctor("Dvar") << "\"" << decl->getNameAsString() << "\""
                           << fmt::nbsp;
        cprint.printQualType(decl->getType(), print);
        print.output() << fmt::nbsp;

        if (decl->hasInit()) {
            print.some();
            cprint.printExpr(decl->getInit(), print, on);
            print.end_ctor();
        } else {
            print.none() << fmt::nbsp;
        }

        print.end_ctor();
        return true;
    }

    bool VisitTypeDecl(const TypeDecl* decl, CoqPrinter&, ClangPrinter& cprint,
                       OpaqueNames&) {
        using namespace logging;
        debug() << "local type declarations are (currently) not well supported "
                << decl->getDeclKindName() << " (at "
                << cprint.sourceRange(decl->getSourceRange()) << ")\n";
        return false;
    }

    bool VisitStaticAssertDecl(const StaticAssertDecl* decl, CoqPrinter&,
                               ClangPrinter&, OpaqueNames&) {
        return false;
    }

    bool VisitDecl(const Decl* decl, CoqPrinter& print, ClangPrinter& cprint,
                   OpaqueNames&) {
        using namespace logging;
        debug() << "unexpected local declaration while printing local decl "
                << decl->getDeclKindName() << " (at "
                << cprint.sourceRange(decl->getSourceRange()) << ")\n";
        return false;
    }

    bool VisitDecompositionDecl(const DecompositionDecl* decl,
                                CoqPrinter& print, ClangPrinter& cprint,
                                OpaqueNames& on) {
        print.ctor("Ddecompose");

        cprint.printExpr(decl->getInit(), print, on);

        int index = on.push_anon(decl);
        print.output() << fmt::nbsp << "\"$" << index << "\"";

        print.output() << fmt::nbsp;

        print.list(decl->bindings(), [&](auto print, auto b) {
            this->Visit(b->getHoldingVar(), print, cprint, on);
        });

        on.pop_anon(decl);

        print.end_ctor();
        return true;
    }
};

PrintLocalDecl PrintLocalDecl::printer;

bool
ClangPrinter::printLocalDecl(const clang::Decl* decl, CoqPrinter& print) {
    OpaqueNames names;
    return PrintLocalDecl::printer.Visit(decl, print, *this, names);
}
