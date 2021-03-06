use std::cmp;
use std::collections::HashMap;
use std::mem;
use std::rc::Rc;
use regex::Regex;
use crate::{NonterminalRef, Chunk};
use crate::builder::{GrammarBuilder, ProductionLhs, ProductionRhs};
use crate::ty::{Ty, CtorTy, VarId};


// TODO: better organization - shouldn't `impl GrammarBuilder` outside the `builder` module
impl GrammarBuilder {
    fn build_ty(&mut self, p: ParsedTy, vars: &HashMap<&str, VarId>) -> Ty {
        if let Some(&var) = vars.get(p.ctor) {
            assert!(p.args.len() == 0, "unexpected args for type variable {:?}", p.ctor);
            return Ty::Var(var);
        }

        let ctor = CtorTy {
            ctor: self.intern_text(p.ctor),
            args: p.args.into_iter().map(|p2| self.build_ty(p2, vars)).collect::<Rc<[_]>>(),
        };
        Ty::Ctor(Rc::new(ctor))
    }

    fn parse_production_lhs<'s>(
        &mut self,
        s: &'s str,
    ) -> (ProductionLhs, HashMap<&'s str, VarId>) {
        let parsed = Parser::from_str(s).parse_lhs_exact().unwrap();
        let vars_map = make_vars_table(&parsed.vars);
        let lhs = ProductionLhs {
            vars: parsed.vars.into_iter().map(|s| self.intern_text(s)).collect(),
            nt: NonterminalRef {
                id: self.nt_id(&parsed.nt.name),
                args: parsed.nt.args.into_iter().map(|p| self.build_ty(p, &vars_map)).collect(),
            },
        };
        (lhs, vars_map)
    }

    fn parse_nonterminal_ref(
        &mut self,
        s: &str,
        vars_map: &HashMap<&str, VarId>,
    ) -> (NonterminalRef, Order) {
        let parsed = Parser::from_str(s).parse_nt_exact(true).unwrap();
        let nt = NonterminalRef {
            id: self.nt_id(&parsed.name),
            args: parsed.args.into_iter().map(|p| self.build_ty(p, &vars_map)).collect(),
        };
        (nt, parsed.order)
    }

    pub fn parse_grammar(&mut self, lines: &[&str]) {
        struct PendingBlock<'a> {
            lhs: ProductionLhs,
            vars_map: HashMap<&'a str, VarId>,
            start_line: usize,
            end_line: usize,
            min_indent: usize,
        }

        let mut cur_block: Option<PendingBlock> = None;
        for (i, line) in lines.iter().enumerate() {
            let trimmed = line.trim_start();
            if let Some(ref mut block) = cur_block {
                if trimmed.len() == 0 {
                    // Internal blank or all-whitespace are accepted, regardless of their
                    // indentation level.  However, we don't update `end_line`, so trailing blank
                    // lines after a block are ignored.
                    continue;
                }

                let indent = line.len() - trimmed.len();
                if indent > 0 {
                    // Include non-blank lines as long as they're indented by some amount.
                    block.min_indent = cmp::min(block.min_indent, indent);
                    block.end_line = i + 1;
                    continue;
                } else {
                    // The first non-indented line marks the end of the block.
                    let block = cur_block.take().unwrap();
                    let rhs = self.parse_block(
                        block.start_line,
                        &lines[block.start_line .. block.end_line],
                        block.min_indent,
                        &block.vars_map,
                    );
                    self.add_prod(block.lhs, rhs);
                }
            }

            // We check this first so that all-whitespace lines are treated like blank ones instead of
            // raising an error.
            if trimmed.len() == 0 || line.starts_with("//") {
                continue;
            }

            if trimmed.len() < line.len() {
                eprintln!("line {}: error: found indented line outside block", i + 1);
                continue;
            }

            if let Some(delim) = line.find("::=") {
                let before = line[.. delim].trim();
                let after = line[delim + 3 ..].trim();
                let (lhs, vars_map) = self.parse_production_lhs(before);

                if after.len() == 0 {
                    // Start of a multi-line block
                    cur_block = Some(PendingBlock {
                        lhs,
                        vars_map,
                        start_line: i + 1,
                        end_line: i + 1,
                        min_indent: usize::MAX,
                    });
                } else {
                    // Single-line case
                    let mut rhs = PartialProductionRhs::default();
                    self.parse_line(&mut rhs, after, false, &vars_map);
                    self.add_prod(lhs, rhs.finish());
                }
            } else {
                eprintln!("line {}: error: expected `::=`", i + 1);
                continue;
            }
        }

        if let Some(block) = cur_block {
            let rhs = self.parse_block(
                block.start_line,
                &lines[block.start_line .. block.end_line],
                block.min_indent,
                &block.vars_map,
            );
            self.add_prod(block.lhs, rhs);
        }
    }


    fn parse_block(
        &mut self,
        first_line: usize,
        lines: &[&str],
        indent: usize,
        vars_map: &HashMap<&str, VarId>,
    ) -> ProductionRhs {
        let nt_line_re = Regex::new(&format!(r"^(\s*){}$", NT_RE)).unwrap();

        let mut prod = PartialProductionRhs::default();
        for (i, line) in lines.iter().enumerate() {
            // The last line never gets a trailing newline.
            let newline = i < lines.len() - 1;

            if line.len() < indent {
                prod.chunks.push(Chunk::Text(self.intern_text(""), newline));
                continue;
            }

            if !line.is_char_boundary(indent) {
                eprintln!("line {}: error: inconsistent indentation", first_line + i + 1);
            }
            let line = &line[indent..];

            if let Some(caps) = nt_line_re.captures(line) {
                let indent_amount = caps.get(1).map(|m| m.end() as isize).unwrap();
                prod.chunks.push(Chunk::Indent(indent_amount));
                let nt_idx = prod.nts.len();
                prod.chunks.push(Chunk::Nt(nt_idx));
                prod.nts.push(self.parse_nonterminal_ref(&caps[2], vars_map));
                prod.chunks.push(Chunk::Indent(-indent_amount));
                prod.chunks.push(Chunk::MagicNewline);
            } else {
                self.parse_line(&mut prod, line, newline, vars_map);
            }
        }
        prod.finish()
    }

    fn parse_line(
        &mut self,
        prod: &mut PartialProductionRhs,
        line: &str,
        full_line: bool,
        vars_map: &HashMap<&str, VarId>,
    ) {
        let mut prev_end = 0;
        let nt_re = Regex::new(NT_RE).unwrap();
        for caps in nt_re.captures_iter(line) {
            let m = caps.get(0).unwrap();

            let start = m.start();
            if start > prev_end {
                let s = self.intern_text(&line[prev_end .. start]);
                prod.chunks.push(Chunk::Text(s, false));
            }
            let nt_idx = prod.nts.len();
            prod.chunks.push(Chunk::Nt(nt_idx));
            prod.nts.push(self.parse_nonterminal_ref(&caps[1], vars_map));

            prev_end = m.end();
        }

        // If full_line is set, we need a final `Text` with `newline` set, even if it contains an
        // empty string.
        if prev_end < line.len() || full_line {
            let s = self.intern_text(&line[prev_end ..]);
            prod.chunks.push(Chunk::Text(s, full_line));
        }
    }
}

const NT_RE: &'static str = r"<<([$^]?[a-zA-Z0-9_]+(\[[a-zA-Z0-9_, \[\]]*\])?)>>";


/// Data for in-progress construction of a `ProductionRhs`.  Notably, the `nts` don't have to be in
/// their final order at this point - they can be added in parsing order, and `finish` will sort
/// them as needed.
#[derive(Default)]
struct PartialProductionRhs {
    chunks: Vec<Chunk>,
    nts: Vec<(NonterminalRef, Order)>,
}

impl PartialProductionRhs {
    fn finish(mut self) -> ProductionRhs {
        // Compute the final order of nonterminals.
        let mut early: Vec<usize> = Vec::new();
        let mut late: Vec<usize> = Vec::new();
        let mut default: Vec<usize> = Vec::with_capacity(self.nts.len());

        for (i, (_, order)) in self.nts.iter().enumerate() {
            match order {
                Order::Default => default.push(i),
                Order::Early => early.push(i),
                Order::Late => late.push(i),
            }
        }

        // The order of nonterminals.  For each output index, `orig_idx` gives the index in
        // `self.nts` where the nonterminal originally appeared.
        let orig_idx: Vec<usize> = early.into_iter()
            .chain(default.into_iter())
            .chain(late.into_iter())
            .collect::<Vec<_>>();

        // The nonterminals, in sorted order.
        let mut nts = Vec::with_capacity(self.nts.len());
        // The reverse of `orig_idx`: for each input index in `self.nts`, `new_idx` gives the
        // position of that nonterminal in the output list.
        let mut new_idx = vec![0; self.nts.len()];
        for i in orig_idx {
            new_idx[i] = nts.len();
            nts.push(mem::take(&mut self.nts[i].0));
        }

        // Remap `Chunk::Nt` chunks using `new_idx`.
        let chunks = self.chunks.into_iter().map(|c| match c {
            Chunk::Nt(i) => Chunk::Nt(new_idx[i]),
            c => c,
        }).collect::<Vec<_>>();

        ProductionRhs { chunks, nts }
    }
}


#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Token<'s> {
    Open,
    Close,
    Comma,
    Word(&'s str),
    Dollar,
    Caret,
}

fn tokenize<'s>(s: &'s str) -> Vec<Token<'s>> {
    let word_re = Regex::new(r"^[a-zA-Z0-9_]+").unwrap();
    let space_re = Regex::new(r"^\s+").unwrap();

    let mut s = s;
    let mut tokens = Vec::new();
    while s.len() > 0 {
        if let Some(word) = word_re.find(s) {
            tokens.push(Token::Word(word.as_str()));
            s = &s[word.end()..];
        } else if let Some(space) = space_re.find(s) {
            s = &s[space.end()..];
        } else {
            match s.chars().next().unwrap() {
                '[' => tokens.push(Token::Open),
                ']' => tokens.push(Token::Close),
                ',' => tokens.push(Token::Comma),
                '$' => tokens.push(Token::Dollar),
                '^' => tokens.push(Token::Caret),
                c => panic!("unexpected character {:?}", c),
            }
            s = &s[1..];
        }
    }
    tokens
}

struct Parser<'s> {
    tokens: Vec<Token<'s>>,
    pos: usize,
}

type PResult<T> = Result<T, ()>;

enum Order {
    Default,
    Early,
    Late,
}

struct ParsedNt<'s> {
    name: &'s str,
    args: Vec<ParsedTy<'s>>,
    order: Order,
}

struct ParsedTy<'s> {
    ctor: &'s str,
    args: Vec<ParsedTy<'s>>,
}

struct ParsedLhs<'s> {
    vars: Vec<&'s str>,
    nt: ParsedNt<'s>,
}

impl<'s> Parser<'s> {
    pub fn new(tokens: Vec<Token<'s>>) -> Parser<'s> {
        Parser {
            tokens,
            pos: 0,
        }
    }

    pub fn from_str(s: &'s str) -> Parser<'s> {
        Self::new(tokenize(s))
    }

    pub fn eof(&self) -> bool {
        self.pos >= self.tokens.len()
    }

    pub fn peek(&self) -> PResult<Token<'s>> {
        let t = self.tokens.get(self.pos).ok_or(())?.clone();
        Ok(t)
    }

    pub fn take(&mut self) -> PResult<Token<'s>> {
        let t = self.peek()?;
        self.pos += 1;
        Ok(t)
    }

    pub fn take_word(&mut self) -> PResult<&'s str> {
        match self.take()? {
            Token::Word(s) => Ok(s),
            _ => Err(()),
        }
    }

    pub fn eat(&mut self, t: Token) -> bool {
        if self.tokens.get(self.pos) == Some(&t) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    pub fn eat_word(&mut self, s: &str) -> bool {
        if self.tokens.get(self.pos) == Some(&Token::Word(s)) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    pub fn expect(&mut self, t: Token) -> PResult<()> {
        if !self.eat(t) {
            Err(())
        } else {
            Ok(())
        }
    }

    pub fn expect_eof(&self) -> PResult<()> {
        if self.eof() {
            Ok(())
        } else {
            Err(())
        }
    }

    pub fn parse_ty_list(&mut self) -> PResult<Vec<ParsedTy<'s>>> {
        let mut tys = Vec::new();
        if self.eat(Token::Open) {
            loop {
                tys.push(self.parse_ty()?);
                if self.eat(Token::Close) {
                    break;
                } else {
                    self.expect(Token::Comma)?;
                }
            }
        }
        Ok(tys)
    }

    pub fn parse_ty(&mut self) -> PResult<ParsedTy<'s>> {
        let ctor = self.take_word()?;
        let args = self.parse_ty_list()?;
        Ok(ParsedTy { ctor, args })
    }

    pub fn parse_nt(&mut self, accept_order: bool) -> PResult<ParsedNt<'s>> {
        let early = if accept_order { self.eat(Token::Caret) } else { false };
        let late = if accept_order { self.eat(Token::Dollar) } else { false };

        let name = self.take_word()?;
        let args = self.parse_ty_list()?;
        let order = match (early, late) {
            (false, false) => Order::Default,
            (true, false) => Order::Early,
            (false, true) => Order::Late,
            _ => return Err(()),
        };
        Ok(ParsedNt { name, args, order })
    }

    pub fn parse_nt_exact(&mut self, accept_order: bool) -> PResult<ParsedNt<'s>> {
        let x = self.parse_nt(accept_order)?;
        self.expect_eof()?;
        Ok(x)
    }

    pub fn parse_lhs(&mut self) -> PResult<ParsedLhs<'s>> {
        let mut vars = Vec::new();
        if self.eat_word("for") {
            self.expect(Token::Open)?;
            loop {
                vars.push(self.take_word()?);
                if self.eat(Token::Close) {
                    break;
                } else {
                    self.expect(Token::Comma)?;
                }
            }
        }

        let nt = self.parse_nt(false)?;
        Ok(ParsedLhs { vars, nt })
    }

    pub fn parse_lhs_exact(&mut self) -> PResult<ParsedLhs<'s>> {
        let x = self.parse_lhs()?;
        self.expect_eof()?;
        Ok(x)
    }
}

fn make_vars_table<'a>(vars: &[&'a str]) -> HashMap<&'a str, VarId> {
    assert!(vars.len() <= u32::MAX as usize);
    vars.iter().enumerate().map(|(idx, &name)| (name, VarId(idx as u32))).collect()
}
