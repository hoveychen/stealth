// `border-radius` is the one four-value box shorthand the table left
// `.unmodelled`, and the reason is the `/`: it is two box lists, one for the
// horizontal radii and one for the vertical, distributed over four corner
// longhands that each hold a *pair*. Nothing else in the table has that shape.
//
// This reads the whole of it: how many components each side takes and which
// corner each lands on, what a corner holds when only one side was written,
// how the value comes back (both lists elided independently, and the `/`
// dropped when the two agree), and the same for the four `-webkit-border-*-
// radius` and logical spellings in case they are not the same parser. What it
// said, over 168 readings on headed Chrome 151:
//
//   * The horizontal list distributes by the box rule -- 1 fills all four, 2
//     is (TL/BR, TR/BL), 3 is (TL, TR/BL, BR), 4 is TL TR BR BL -- and so does
//     the vertical one. Each corner longhand then stores the pair `h v`,
//     shortened to `h` when the two agree, which is why a value with no `/`
//     leaves every corner holding one component.
//   * Coming back, each list is elided by the box rule *independently* (drop
//     the fourth when it equals the second, then the third when it equals the
//     first, then the second when it equals the first) and the `/` is dropped
//     when the two lists come out identical: `10px 20px / 10px 20px` reads
//     `10px 20px`, `10px 10px / 20px 20px` reads `10px / 20px`.
//   * A corner longhand takes one or two components and nothing else: three
//     is rejected, and so is a `/`. The logical spellings
//     (`border-start-start-radius` and friends) are corners, not shorthands.
//   * `-webkit-border-radius` is NOT the same parser. With one, three or four
//     components it is `border-radius`; with *two* it is the legacy WebKit
//     form, horizontal-then-vertical rather than TL-then-TR --
//     `-webkit-border-radius: 10px 20px` is `10px / 20px` where
//     `border-radius: 10px 20px` is `10px 20px`.
//   * Rejected outright: five components, `auto`, `none`, a negative length,
//     an empty side of the `/`, and a second `/`.
//
// One reading here is out of this plan's reach: Chrome evaluates the calc,
// answering `calc(15px)` for `calc(10px + 5px)`, where this engine keeps a
// substituted value byte for byte. That is the calc gap, not the radius one.
(() => {
    const values = [
        // The horizontal list alone, one to four components.
        '10px', '10px 20px', '10px 20px 30px', '10px 20px 30px 40px',
        // Elision: a list that repeats comes back shorter.
        '10px 10px', '10px 10px 10px', '10px 10px 10px 10px',
        '10px 20px 10px', '10px 20px 10px 20px', '10px 20px 30px 20px',
        '10px 20px 10px 30px', '10px 20px 30px 10px',
        // The slash, both sides, every combination of lengths.
        '10px / 10px', '10px / 20px', '10px 20px / 10px 20px',
        '10px 20px / 30px 40px', '10px / 20px 30px', '10px 20px 30px / 40px',
        '10px 20px 30px 40px / 50px 60px 70px 80px',
        '10px 10px / 20px 20px', '10px 20px / 20px 10px',
        // Percentages, calc, and a zero -- the unit rules ride along.
        '50%', '50% 25%', '0', '0 0', '0 10px', '10px 0',
        '50% / 25%', 'calc(10px + 5px)', 'calc(10px + 5px) 20px',
        '1em 2ex', '0px 0%', '0% 0px',
        // Shapes Chrome throws away, so a model that takes one is wrong.
        '10px 20px 30px 40px 50px', 'auto', '-10px', '10px / ', '/ 10px',
        '10px / 20px / 30px', 'none',
        // And the CSS-wide keywords.
        'inherit', 'initial', 'unset', 'revert',
    ];

    // The corner longhands take the pair directly, which is the other half of
    // the grammar: whatever the shorthand distributes, a corner stores as
    // `h v` and elides to `h` when they agree.
    const cornerValues = [
        '10px', '10px 10px', '10px 20px', '50%', '50% 50%', '50% 25%',
        '0', '0 0', '0 10px', '10px 0', '10px 10px 10px', '10px / 20px',
    ];

    const out = {};
    const read = (property, value) => {
        const el = document.createElement('div');
        el.style.setProperty(property, value);
        const names = [];
        for (let i = 0; i < el.style.length; i++) names.push(el.style.item(i));
        out[`${property}: ${value}`] = {
            items: names,
            values: names.map((n) => el.style.getPropertyValue(n)),
            read: el.style.getPropertyValue(property),
            cssText: el.style.cssText,
        };
    };
    for (const value of values) {
        read('border-radius', value);
        read('-webkit-border-radius', value);
        read('border-start-start-radius', value);
    }
    for (const value of cornerValues) {
        read('border-top-left-radius', value);
        read('border-bottom-right-radius', value);
        read('border-start-end-radius', value);
    }
    return out;
})()
