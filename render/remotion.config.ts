import { Config } from "@remotion/cli/config";

// Use Apple's hardware encoder where available.
Config.setVideoImageFormat("jpeg");
Config.setConcurrency(null); // auto
Config.setOverwriteOutput(true);
