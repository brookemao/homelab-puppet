# llama_dgpu_pci fact: PCI slot (e.g. '0000:03:00.0') of the discrete AMD GPU
# used for llama.cpp Vulkan inference.
#
# Matches the Navi 48 (Radeon AI PRO R9700) VGA controller in lspci output.
# Absent when lspci is unavailable or no matching device exists; callers fall
# back to the known-good slot.
Facter.add(:llama_dgpu_pci) do
  setcode do
    lspci = Facter::Core::Execution.which('lspci')
    if lspci.nil? || lspci.empty?
      nil
    else
      line = Facter::Core::Execution.execute("#{lspci} -D").lines.find do |l|
        l.include?('Navi 48')
      end
      line ? line.split.first : nil
    end
  end
end
