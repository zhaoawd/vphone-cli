var log = fs.read("/var/mobile/Library/Caches/vphone-folddisplay.log");
print(typeof log === "string" ? log.split("\n").slice(-25).join("\n") : JSON.stringify(log));
