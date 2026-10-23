use crate::types::{PriceMap, Usage};

fn n(x: f64) -> f64 {
    if x.is_nan() { 0.0 } else { x }
}

pub fn compute_cost(usage: Option<&Usage>, price_map: &PriceMap, model: &str) -> Option<f64> {
    let usage = usage?;
    let price = price_map.get(model)?;
    Some(
        (n(usage.input_tokens) * price.input
            + n(usage.output_tokens) * price.output
            + n(usage.cache_read_tokens) * price.cache_read
            + n(usage.cache_write_tokens) * price.cache_write)
            / 1e6,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Price;
    use std::collections::HashMap;

    fn price_map() -> PriceMap {
        let mut m = HashMap::new();
        m.insert(
            "composer-2.5".into(),
            Price {
                input: 0.5,
                output: 2.5,
                cache_read: 0.2,
                cache_write: 0.0,
            },
        );
        m.insert(
            "grok-4.5-xhigh".into(),
            Price {
                input: 2.0,
                output: 6.0,
                cache_read: 0.5,
                cache_write: 0.0,
            },
        );
        m.insert(
            "gpt-5.5-high".into(),
            Price {
                input: 5.0,
                output: 30.0,
                cache_read: 0.5,
                cache_write: 0.0,
            },
        );
        m
    }

    fn usage() -> Usage {
        Usage {
            input_tokens: 1_000_000.0,
            output_tokens: 1_000_000.0,
            cache_read_tokens: 0.0,
            cache_write_tokens: 0.0,
            calls: None,
            allowance: None,
        }
    }

    #[test]
    fn null_usage_is_null() {
        assert_eq!(compute_cost(None, &price_map(), "composer-2.5"), None);
    }

    #[test]
    fn missing_price_is_null() {
        assert_eq!(
            compute_cost(Some(&usage()), &price_map(), "unknown-model"),
            None
        );
    }

    #[test]
    fn composer_cost() {
        assert_eq!(
            compute_cost(Some(&usage()), &price_map(), "composer-2.5"),
            Some(3.0)
        );
    }

    #[test]
    fn grok_cost() {
        assert_eq!(
            compute_cost(Some(&usage()), &price_map(), "grok-4.5-xhigh"),
            Some(8.0)
        );
    }

    #[test]
    fn gpt_cost() {
        assert_eq!(
            compute_cost(Some(&usage()), &price_map(), "gpt-5.5-high"),
            Some(35.0)
        );
    }

    #[test]
    fn bare_id_not_aliased() {
        assert_eq!(compute_cost(Some(&usage()), &price_map(), "gpt-5.5"), None);
    }

    #[test]
    fn missing_usage_fields_are_zero() {
        let partial = Usage {
            output_tokens: 1_000_000.0,
            ..Usage::default()
        };
        assert_eq!(
            compute_cost(Some(&partial), &price_map(), "composer-2.5"),
            Some(2.5)
        );
    }
}
