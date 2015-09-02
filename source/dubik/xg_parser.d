/*
 *  Dubik - A D language implementation of the UBIK protocol
 *  Copyright (C) 2015 Paul O'Neil
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module dubik.xg_parser;

import pegged.grammar;

mixin(grammar(`
XG:
    Definition          <- (Prefix / Constant / Define / Typedef / Struct / Package / StatIndex / Call)*
    Prefix              <  "prefix" identifier
    Constant            <  "const" identifier :'=' Number :';'
    Define              <  "#define" identifier Number
    Typedef             <  "typedef" Type identifier (:'<' (PositiveInteger / identifier) :'>')? :';'
    Struct              <  "struct" identifier :'{' StructBody :'}' :';'
    StructBody          <  StructMember*
    StructMember        <  Type identifier ((:'[' (PositiveInteger / identifier) :']' :';') / :';')
    Package             <  "package" identifier
    StatIndex           <  "statindex" PositiveInteger
    Call                <  identifier '(' (Argument (',' Argument)*)? ')' ("multi" / "split")? '=' (Number / identifier) ';'

    Type                <  ("struct" / "union")? identifier ('*')*

    Argument            <  ("IN" / "OUT")? Type identifier

    Number              <- Integer
    Integer             <- '-'? PositiveInteger
    PositiveInteger     <- [0-9]+

    Comment             <- MultiCommentBegin (!MultiCommentEnd .)* MultiCommentEnd
    MultiCommentBegin   <- "/*"
    MultiCommentEnd     <- "*/"

    EOL                 <- ('\n' / '\r\n' / '\r')
    Spacing             <- :(' ' / '\t' / '\f' / EOL / Comment)*
    EOI                 <- !.
`));
