use crate::backends::Backend;
use crate::types::{Config, ModelEntry, ResolvedModel};
use std::collections::HashMap;

/// The `claude --effort` values; a Claude model id may end in `:<one of these>` (#157).
pub const CLAUDE_EFFORT_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// The `muse exec --reasoning-effort` values; a Muse model id may end in `:<one of these>`.
pub const MUSE_EFFORT_LEVELS: [&str; 8] = [
    "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
];

/// Resolves a model id to its models.json row id. An exact key wins; otherwise a
/// trailing `:<level>` is stripped only when the base is a key whose backend is
/// `claude` and the level is one of [`CLAUDE_EFFORT_LEVELS`], or whose backend is
/// `muse` and the level is one of [`MUSE_EFFORT_LEVELS`]. An invalid level on a
/// Claude base is an error (a plain message, not [`ModelNotAllowedError`]); everything
/// else passes through whole and the caller rejects it as unknown.
pub fn base_model_id<'a>(
    model: &'a str,
    models: &HashMap<String, ModelEntry>,
) -> Result<&'a str, String> {
    if models.contains_key(model) {
        return Ok(model);
    }
    let Some((base, level)) = model.rsplit_once(':') else {
        return Ok(model);
    };
    let Some(entry) = models.get(base) else {
        return Ok(model);
    };
    match entry.backend.as_str() {
        "muse" if MUSE_EFFORT_LEVELS.contains(&level) => Ok(base),
        "claude" if CLAUDE_EFFORT_LEVELS.contains(&level) => Ok(base),
        "claude" => Err(format!(
            "model \"{model}\": unknown effort level \"{level}\"; \
             use one of {}",
            CLAUDE_EFFORT_LEVELS.join(", ")
        )),
        _ => Ok(model),
    }
}

#[derive(Debug)]
pub struct ModelNotAllowedError {
    pub message: String,
}

impl std::fmt::Display for ModelNotAllowedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for ModelNotAllowedError {}

pub fn resolve_model(
    model: Option<&str>,
    config: &impl ConfigLike,
) -> Result<ResolvedModel, Box<dyn std::error::Error + Send + Sync>> {
    let model = model
        .map(|s| s.to_string())
        .unwrap_or_else(|| config.default_model().to_string());
    let entry_id = base_model_id(&model, config.models())?;
    let entry = config.models().get(entry_id).ok_or_else(|| {
        Box::new(ModelNotAllowedError {
            message: format!("model \"{model}\" is not in the allow-list"),
        }) as Box<dyn std::error::Error + Send + Sync>
    })?;
    if Backend::from_name(&entry.backend).is_none() {
        return Err(format!(
            "model \"{model}\" uses backend \"{}\", which is not implemented yet",
            entry.backend
        )
        .into());
    }
    Ok(ResolvedModel {
        model,
        backend: entry.backend.clone(),
        price: entry.price,
    })
}

pub trait ConfigLike {
    fn default_model(&self) -> &str;
    fn models(&self) -> &std::collections::HashMap<String, crate::types::ModelEntry>;
}

impl ConfigLike for Config {
    fn default_model(&self) -> &str {
        &self.default
    }
    fn models(&self) -> &std::collections::HashMap<String, crate::types::ModelEntry> {
        &self.models
    }
}

impl ConfigLike
    for (
        &str,
        &std::collections::HashMap<String, crate::types::ModelEntry>,
    )
{
    fn default_model(&self) -> &str {
        self.0
    }
    fn models(&self) -> &std::collections::HashMap<String, crate::types::ModelEntry> {
        self.1
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ModelEntry, Price};
    use std::collections::HashMap;

    fn price(input: f64, output: f64, cache_read: f64, cache_write: f64) -> Price {
        Price {
            input,
            output,
            cache_read,
            cache_write,
        }
    }

    fn base() -> (String, HashMap<String, ModelEntry>) {
        let mut models = HashMap::new();
        models.insert(
            "composer-2.5".into(),
            ModelEntry {
                label: "Composer 2.5".into(),
                backend: "cursor".into(),
                price: price(0.5, 2.5, 0.2, 0.0),
                tiers: vec![],
            },
        );
        models.insert(
            "grok-4.7-high".into(),
            ModelEntry {
                label: "Grok 4.7 High".into(),
                backend: "cursor".into(),
                price: price(2.0, 6.0, 0.5, 0.0),
                tiers: vec![],
            },
        );
        models.insert(
            "openai/gpt-6-luna".into(),
            ModelEntry {
                label: "GPT-6 Luna".into(),
                backend: "pi".into(),
                price: price(0.1, 0.5, 0.01, 0.125),
                tiers: vec![],
            },
        );
        models.insert(
            "claude-fable-5-1".into(),
            ModelEntry {
                label: "Claude Fable 5.1".into(),
                backend: "claude".into(),
                price: price(10.0, 50.0, 0.25, 12.5),
                tiers: vec![],
            },
        );
        models.insert(
            "claude-sonnet-5-5".into(),
            ModelEntry {
                label: "Claude Sonnet 5.5".into(),
                backend: "claude".into(),
                price: price(2.0, 10.0, 0.2, 2.5),
                tiers: vec![],
            },
        );
        ("composer-2.5".into(), models)
    }

    #[test]
    fn omitted_model_resolves_to_default() {
        let (d, m) = base();
        let r = resolve_model(None, &(d.as_str(), &m)).unwrap();
        assert_eq!(r.model, "composer-2.5");
        assert_eq!(r.backend, "cursor");
        assert_eq!(r.price, m["composer-2.5"].price);
    }

    #[test]
    fn allowed_id_resolves_with_backend_and_price() {
        let (d, m) = base();
        let r = resolve_model(Some("grok-4.7-high"), &(d.as_str(), &m)).unwrap();
        assert_eq!(r.model, "grok-4.7-high");
        assert_eq!(r.backend, "cursor");
        assert_eq!(r.price, m["grok-4.7-high"].price);
    }

    #[test]
    fn unknown_id_throws_model_not_allowed() {
        let (d, m) = base();
        let e = resolve_model(Some("not-listed"), &(d.as_str(), &m)).unwrap_err();
        assert!(e.downcast_ref::<ModelNotAllowedError>().is_some());
    }

    #[test]
    fn claude_backend_resolves() {
        let (d, m) = base();
        let r = resolve_model(Some("claude-sonnet-5-5"), &(d.as_str(), &m)).unwrap();
        assert_eq!(r.model, "claude-sonnet-5-5");
        assert_eq!(r.backend, "claude");
        assert_eq!(r.price, m["claude-sonnet-5-5"].price);
    }

    #[test]
    fn suffixed_claude_id_resolves_as_its_base() {
        let (d, m) = base();
        for (id, base_id) in [
            ("claude-fable-5-1:low", "claude-fable-5-1"),
            ("claude-sonnet-5-5:max", "claude-sonnet-5-5"),
        ] {
            let r = resolve_model(Some(id), &(d.as_str(), &m)).unwrap();
            assert_eq!(r.model, id, "{id}");
            assert_eq!(r.backend, "claude", "{id}");
            assert_eq!(r.price, m[base_id].price, "{id}");
        }
    }

    #[test]
    fn suffixed_muse_id_resolves_as_its_base() {
        let (d, mut m) = base();
        let entry = ModelEntry {
            label: "Muse Spark 1.3 Contributor (muse)".into(),
            backend: "muse".into(),
            price: price(0.1, 0.2, 0.002, 0.0),
            tiers: vec![],
        };
        m.insert("muse/muse-spark-1.3-contributor".into(), entry);
        for id in [
            "muse/muse-spark-1.3-contributor:high",
            "muse/muse-spark-1.3-contributor:ultra",
        ] {
            let r = resolve_model(Some(id), &(d.as_str(), &m)).unwrap();
            assert_eq!(r.model, id, "{id}");
            assert_eq!(r.backend, "muse", "{id}");
            assert_eq!(r.price, m["muse/muse-spark-1.3-contributor"].price, "{id}");
        }
        // A colon that is not a Muse level is part of the name, so it is unknown.
        let e = resolve_model(
            Some("muse/muse-spark-1.3-contributor:beta"),
            &(d.as_str(), &m),
        )
        .unwrap_err();
        assert!(e.downcast_ref::<ModelNotAllowedError>().is_some());
    }

    #[test]
    fn bad_effort_level_is_a_plain_error_naming_the_levels() {
        let (d, m) = base();
        for id in [
            "claude-fable-5-1:bogus",
            "claude-fable-5-1:",
            "claude-fable-5-1:LOW",
        ] {
            let e = resolve_model(Some(id), &(d.as_str(), &m)).unwrap_err();
            assert!(
                e.downcast_ref::<ModelNotAllowedError>().is_none(),
                "{id} should not be a ModelNotAllowedError"
            );
            let msg = e.to_string();
            assert!(msg.contains(&format!("model \"{id}\"")), "{msg}");
            assert!(msg.contains("unknown effort level"), "{msg}");
            assert!(msg.contains("low, medium, high, xhigh, max"), "{msg}");
        }
    }

    #[test]
    fn suffix_on_non_claude_id_is_unknown_model() {
        let (d, m) = base();
        for id in ["composer-2.5:low", "nope:low"] {
            let e = resolve_model(Some(id), &(d.as_str(), &m)).unwrap_err();
            assert!(
                e.downcast_ref::<ModelNotAllowedError>().is_some(),
                "{id} should be a ModelNotAllowedError"
            );
        }
    }

    #[test]
    fn pi_backend_resolves() {
        let (d, m) = base();
        let r = resolve_model(Some("openai/gpt-6-luna"), &(d.as_str(), &m)).unwrap();
        assert_eq!(r.model, "openai/gpt-6-luna");
        assert_eq!(r.backend, "pi");
        assert_eq!(r.price, m["openai/gpt-6-luna"].price);
    }
}
