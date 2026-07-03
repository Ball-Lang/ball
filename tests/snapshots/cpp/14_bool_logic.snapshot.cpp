
namespace {

BallDyn identity(bool b);

BallDyn identity(bool b) {
    auto& input = b;
    return b;
    return BallDyn();
}

} // namespace

int main() {
    auto t = BallDyn(identity(true));
    auto f = BallDyn(identity(false));
    std::cout << ball_to_string(ball_to_string((t && t))) << std::endl;
    std::cout << ball_to_string(ball_to_string((t && f))) << std::endl;
    std::cout << ball_to_string(ball_to_string((t || f))) << std::endl;
    std::cout << ball_to_string(ball_to_string((!f))) << std::endl;
    return 0;
}
