
namespace {


} // namespace

int main() {
    auto name = BallDyn("world"s);
    std::cout << ball_to_string(("hello, "s + name)) << std::endl;
    std::cout << ball_to_string(("hello, "s + ball_to_string(name))) << std::endl;
    std::cout << ball_to_string(ball_to_string(ball_length(name))) << std::endl;
    std::cout << ball_to_string([](std::string s){std::transform(s.begin(),s.end(),s.begin(),::toupper);return s;}(name)) << std::endl;
    return 0;
}
