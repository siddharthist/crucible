extern crate crucible;
use crucible::*;

#[cfg_attr(crux, crux_test)]
fn crux_test() -> i32 {
    let mut result = 0;
    if bool::symbolic("cond") {
        let mut r = &mut result;
        let r2 = &mut r;
        **r2 = 1;
    }
    result
}

pub fn main() {
    println!("{:?}", crux_test());
}

