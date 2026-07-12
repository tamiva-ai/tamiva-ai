import { Queue } from "bullmq";

export const connection = {
  url: process.env.REDIS_URL ?? "redis://localhost:6379",
  maxRetriesPerRequest: null as null,
};

export const generationQueue = new Queue("generation", { connection });

export interface LogoJobData {
  projectId: string;
  prompt: string;
  referenceImageUrls?: string[];
}

export interface CarouselJobData {
  projectId: string;
  /** Image prompt per slide, parallel to slideReferenceImageUrls. */
  slidePrompts: string[];
  /** Per-slide reference image URLs. Each entry is either an empty array
   *  (text-only) or one or more URLs to condition on via OpenAI's edits
   *  endpoint. Length must match slidePrompts. */
  slideReferenceImageUrls?: string[][];
}

export interface VideoJobData {
  projectId: string;
  stage: "hero_image" | "storyboard" | "video_prompt" | "render" | "composite";
  prompt: string;
  referenceImageUrls: string[];
  tier: "draft" | "final";
  /** Optional explicit first-frame anchor; falls back to references[0]. */
  firstFrameUrl?: string;
  lastFrameUrl?: string;
  durationSeconds?: number;
}

export async function enqueueLogoJob(data: LogoJobData) {
  return generationQueue.add("logo", data, {
    attempts: 3,
    backoff: { type: "exponential", delay: 5000 },
  });
}

export async function enqueueCarouselJob(data: CarouselJobData) {
  return generationQueue.add("carousel", data, {
    attempts: 3,
    backoff: { type: "exponential", delay: 5000 },
  });
}

export async function enqueueVideoStage(data: VideoJobData) {
  return generationQueue.add(`video:${data.stage}`, data, {
    attempts: 3,
    backoff: { type: "exponential", delay: 10000 },
  });
}
