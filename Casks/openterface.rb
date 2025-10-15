cask "openterface" do
  version "1.16"
  sha256 "ff73104ca2576f67bdccacdcfc7b0f82cacdec5be1a462c8776b7b677c5205fd"

  url "https://github.com/TechxArtisanStudio/Openterface_MacOS/releases/download/v#{version}/Openterface.dmg",
  verified: "github.com/TechxArtisanStudio/Openterface_MacOS"

  name "Openterface"
  desc "Openterface Mini-KVM allows you to control a headless target device, such as a mini PC, kiosk, or server, directly from your laptop or desktop without the need for an extra keyboard, mouse, and monitor."
  homepage "https://openterface.com"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :monterey"

  app "openterface.app"
end
