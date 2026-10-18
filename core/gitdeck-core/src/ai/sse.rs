//! Server-Sent Events 解析（Anthropic 与 OpenAI 兼容接口的流式响应都使用它）。

use std::io::BufRead;

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct SseEvent {
    pub event: String,
    pub data: String,
}

pub(crate) struct SseReader<R> {
    reader: R,
    buf: Vec<u8>,
}

impl<R: BufRead> SseReader<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            buf: Vec::new(),
        }
    }

    /// 读取下一个事件；流结束时返回 `None`。
    pub fn next_event(&mut self) -> std::io::Result<Option<SseEvent>> {
        let mut event = SseEvent::default();
        let mut has_content = false;
        loop {
            self.buf.clear();
            if self.reader.read_until(b'\n', &mut self.buf)? == 0 {
                return Ok(has_content.then_some(event));
            }
            let line = String::from_utf8_lossy(&self.buf);
            let line = line.trim_end_matches(['\n', '\r']);
            if line.is_empty() {
                if has_content {
                    return Ok(Some(event));
                }
                continue;
            }
            if line.starts_with(':') {
                continue;
            }
            let (field, value) = line.split_once(':').unwrap_or((line, ""));
            let value = value.strip_prefix(' ').unwrap_or(value);
            match field {
                "event" => {
                    event.event = value.to_owned();
                    has_content = true;
                }
                "data" => {
                    if !event.data.is_empty() {
                        event.data.push('\n');
                    }
                    event.data.push_str(value);
                    has_content = true;
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_events_and_comments() {
        let text = ": ping\n\nevent: message_start\ndata: {\"a\":1}\n\ndata: line1\r\ndata: line2\r\n\r\ndata: [DONE]\n";
        let mut reader = SseReader::new(text.as_bytes());
        let first = reader.next_event().unwrap().unwrap();
        assert_eq!(first.event, "message_start");
        assert_eq!(first.data, "{\"a\":1}");
        let second = reader.next_event().unwrap().unwrap();
        assert_eq!(second.event, "");
        assert_eq!(second.data, "line1\nline2");
        assert_eq!(reader.next_event().unwrap().unwrap().data, "[DONE]");
        assert_eq!(reader.next_event().unwrap(), None);
    }
}
